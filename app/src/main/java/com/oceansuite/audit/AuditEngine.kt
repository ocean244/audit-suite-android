package com.oceansuite.audit

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStream
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

object AuditEngine {

    private val defaultSuffixes = listOf(
        "", "-backup", "-backups", "-dev", "-stage", "-staging",
        "-prod", "-production", "-assets", "-static", "-media",
        "-uploads", "-public", "-private", "-internal", "-logs",
        "-data", "-archive", "-cdn", "-web", "-app", "-files", "-db", "-test"
    )

    private val homoglyphs = mapOf(
        'a' to listOf("а", "à", "á", "â", "ä"),
        'c' to listOf("с", "ç"),
        'e' to listOf("е", "è", "é", "ê", "ë"),
        'i' to listOf("і", "ì", "í", "î", "ï", "l", "1"),
        'l' to listOf("1", "i", "|"),
        'o' to listOf("о", "ò", "ó", "ô", "ö", "0"),
        'p' to listOf("р"),
        's' to listOf("ѕ", "5"),
        'w' to listOf("vv"),
        'x' to listOf("х"),
        'y' to listOf("у", "ý", "ÿ")
    )

    private val commonTlds = listOf(
        "com", "net", "org", "io", "co", "pl", "eu", "biz", "info", "xyz", "app", "dev"
    )

    private val defaultWordlist = listOf(
        "123456", "password", "12345678", "qwerty", "123456789", "admin",
        "letmein", "welcome", "monkey", "dragon", "football", "iloveyou",
        "123123", "sunshine", "princess", "password1", "qwerty123", "root",
        "toor", "pass123", "changeme", "master"
    )

    fun normalizeBrand(brand: String): String {
        var cleaned = brand.trim().lowercase()
        cleaned = cleaned.replace(Regex("^https?://"), "")
        cleaned = cleaned.split("/").firstOrNull() ?: ""
        if ("." in cleaned && !cleaned.endsWith(".com")) {
            val ignored = setOf("www", "com", "pl", "org", "net", "io", "co")
            val parts = cleaned.split(".").filter { it.isNotBlank() && it !in ignored }
            if (parts.isNotEmpty()) {
                cleaned = parts.joinToString("-")
            }
        }
        cleaned = cleaned.replace(Regex("[^a-z0-9-]"), "-")
        cleaned = cleaned.replace(Regex("-{2,}"), "-").trim('-')
        require(cleaned.isNotEmpty()) { "Nazwa marki lub domeny po normalizacji jest pusta." }
        return cleaned
    }

    fun generateBucketCandidates(brand: String, customWordsCsv: String = ""): List<String> {
        val base = normalizeBrand(brand)
        val compact = base.replace("-", "")
        val roots = linkedSetOf(base)
        if (compact.isNotEmpty() && compact != base) {
            roots.add(compact)
        }
        customWordsCsv.split(",")
            .map { it.trim().lowercase().replace(Regex("[^a-z0-9-]"), "") }
            .filter { it.isNotEmpty() }
            .forEach { w ->
                roots.add("$base-$w")
                roots.add("$w-$base")
                roots.add("$compact-$w")
            }

        val out = linkedSetOf<String>()
        for (root in roots.sorted()) {
            for (suffix in defaultSuffixes) {
                val candidate = "$root$suffix"
                if (candidate.length in 3..63) {
                    out.add(candidate)
                }
            }
        }
        return out.toList()
    }

    suspend fun scanBuckets(brand: String, customWordsCsv: String = ""): String =
        withContext(Dispatchers.IO) {
            val candidates = generateBucketCandidates(brand, customWordsCsv)
            val findings = coroutineScope {
                candidates.flatMap { name ->
                    listOf(
                        async { probeS3(name) },
                        async { probeGcs(name) }
                    )
                }.awaitAll()
            }
            val publicItems = findings.filter { it.startsWith("[PUBLIC_LISTABLE]") }
            val restrictedItems = findings.filter { it.startsWith("[RESTRICTED]") }

            buildString {
                appendLine("=== BUCKET BUSTER REPORT ===")
                appendLine("Marka bazowa: ${normalizeBrand(brand)}")
                appendLine("Liczba kandydatów: ${candidates.size} (testów: ${findings.size})")
                appendLine("Publiczne (listable): ${publicItems.size}")
                appendLine("Chronione (401/403): ${restrictedItems.size}")
                appendLine()
                if (publicItems.isNotEmpty()) {
                    appendLine("--- ZASOBY PUBLICZNE ---")
                    publicItems.forEach { appendLine(it) }
                    appendLine()
                }
                if (restrictedItems.isNotEmpty()) {
                    appendLine("--- ZASOBY CHRONIONE ---")
                    restrictedItems.take(25).forEach { appendLine(it) }
                }
                if (publicItems.isEmpty() && restrictedItems.isEmpty()) {
                    appendLine("Brak wykrytych zasobów publicznych lub chronionych dla wygenerowanych kandydatów.")
                }
            }
        }

    private fun probeS3(bucket: String): String {
        val urlStr = "https://$bucket.s3.amazonaws.com/?list-type=2&max-keys=5"
        return try {
            val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 5000
                readTimeout = 5000
                setRequestProperty("User-Agent", "OceanAuditSuite/1.0")
            }
            val code = conn.responseCode
            val body = readStreamSafe(if (code in 200..299) conn.inputStream else conn.errorStream, 4096)
            conn.disconnect()
            when (code) {
                in 200..299 -> {
                    val keys = Regex("<Key>").findAll(body).count()
                    "[PUBLIC_LISTABLE] S3 | $bucket | HTTP $code | <Key>: $keys | $urlStr"
                }
                403 -> "[RESTRICTED] S3 | $bucket | HTTP 403 (AccessDenied)"
                404 -> "[NOT_FOUND] S3 | $bucket | HTTP 404"
                else -> "[HTTP_$code] S3 | $bucket | HTTP $code"
            }
        } catch (ex: Exception) {
            "[ERR] S3 | $bucket | ${ex.message ?: "Błąd sieci"}"
        }
    }

    private fun probeGcs(bucket: String): String {
        val urlStr = "https://storage.googleapis.com/storage/v1/b/$bucket/o?maxResults=5"
        return try {
            val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 5000
                readTimeout = 5000
                setRequestProperty("User-Agent", "OceanAuditSuite/1.0")
            }
            val code = conn.responseCode
            val body = readStreamSafe(if (code in 200..299) conn.inputStream else conn.errorStream, 8192)
            conn.disconnect()
            when (code) {
                in 200..299 -> {
                    val count = runCatching {
                        val json = JSONObject(body)
                        json.optJSONArray("items")?.length() ?: 0
                    }.getOrDefault(0)
                    "[PUBLIC_LISTABLE] GCS | $bucket | HTTP $code | items: $count | $urlStr"
                }
                401, 403 -> "[RESTRICTED] GCS | $bucket | HTTP $code"
                404 -> "[NOT_FOUND] GCS | $bucket | HTTP 404"
                else -> "[HTTP_$code] GCS | $bucket | HTTP $code"
            }
        } catch (ex: Exception) {
            "[ERR] GCS | $bucket | ${ex.message ?: "Błąd sieci"}"
        }
    }

    fun generateLookalikeDomains(domain: String, limit: Int = 60): List<String> {
        var cleaned = domain.trim().lowercase().trimEnd('.')
        if ("://" in cleaned) {
            cleaned = cleaned.substringAfter("://")
        }
        cleaned = cleaned.substringBefore("/")
        require("." in cleaned) { "Nieprawidłowa nazwa domeny: $domain" }
        val label = cleaned.substringBeforeLast(".")
        val tld = cleaned.substringAfterLast(".")
        require(label.isNotEmpty() && tld.isNotEmpty()) { "Nieprawidłowa struktura domeny: $domain" }

        val variants = linkedSetOf<String>()
        for (i in label.indices) {
            val ch = label[i]
            val omitted = label.removeRange(i, i + 1)
            if (omitted.isNotEmpty()) variants.add("$omitted.$tld")

            val duplicated = label.substring(0, i) + ch + ch + label.substring(i + 1)
            variants.add("$duplicated.$tld")

            if (i + 1 < label.length) {
                val chars = label.toCharArray()
                val tmp = chars[i]
                chars[i] = chars[i + 1]
                chars[i + 1] = tmp
                variants.add("${String(chars)}.$tld")
            }

            homoglyphs[ch].orEmpty().forEach { glyph ->
                val replaced = label.substring(0, i) + glyph + label.substring(i + 1)
                variants.add("$replaced.$tld")
            }
        }
        for (altTld in commonTlds) {
            variants.add("$label.$altTld")
        }
        variants.remove("$label.$tld")
        return variants.sorted().take(limit.coerceAtLeast(1))
    }

    suspend fun auditDomains(domain: String, limit: Int = 60): String =
        withContext(Dispatchers.IO) {
            val candidates = generateLookalikeDomains(domain, limit)
            val resolved = coroutineScope {
                candidates.map { cand ->
                    async {
                        val aRecs = dnsQuery(cand, "A")
                        val mxRecs = dnsQuery(cand, "MX")
                        Triple(cand, aRecs, mxRecs)
                    }
                }.awaitAll()
            }.filter { (_, a, mx) -> a.isNotEmpty() || mx.isNotEmpty() }

            buildString {
                appendLine("=== DOPPELGANGER DNS REPORT ===")
                appendLine("Domena bazowa: ${domain.trim().lowercase()}")
                appendLine("Wygenerowano wariantów: ${candidates.size}")
                appendLine("Aktywne w DNS (A lub MX): ${resolved.size}")
                appendLine()
                if (resolved.isEmpty()) {
                    appendLine("Brak aktywnych rekordów A/MX dla sprawdzonych wariantów.")
                } else {
                    resolved.forEach { (dom, a, mx) ->
                        val mxFlag = if (mx.isNotEmpty()) "MX_ACTIVE" else "NO_MX"
                        appendLine("$dom [$mxFlag] | A=${a.joinToString(",")} | MX=${mx.joinToString(",")}")
                    }
                }
            }
        }

    private fun dnsQuery(name: String, type: String): List<String> {
        return try {
            val encName = URLEncoder.encode(name, StandardCharsets.UTF_8.toString())
            val urlStr = "https://dns.google/resolve?name=$encName&type=$type"
            val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 4000
                readTimeout = 4000
                setRequestProperty("Accept", "application/dns-json")
            }
            val code = conn.responseCode
            val raw = readStreamSafe(if (code in 200..299) conn.inputStream else conn.errorStream, 8192)
            conn.disconnect()
            if (code !in 200..299) return emptyList()

            val root = JSONObject(raw)
            val arr = root.optJSONArray("Answer") ?: return emptyList()
            val list = mutableListOf<String>()
            for (i in 0 until arr.length()) {
                val item = arr.optJSONObject(i) ?: continue
                val data = item.optString("data", "").trimEnd('.')
                if (data.isNotEmpty()) list.add(data)
            }
            list
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun detectHashAlgorithm(digestHex: String): String {
        val clean = digestHex.trim().lowercase()
        require(clean.matches(Regex("^[0-9a-f]+$"))) {
            "Skrót musi składać się wyłącznie ze znaków heksadecymalnych (0-9, a-f)."
        }
        return when (clean.length) {
            32 -> "MD-5"
            40 -> "SHA-1"
            64 -> "SHA-256"
            else -> throw IllegalArgumentException(
                "Nieobsługiwana długość skrótu (${clean.length}). Obsługiwane: 32 (MD5), 40 (SHA1), 64 (SHA256)."
            )
        }
    }

    fun crackHash(digestHex: String, customCandidatesText: String = ""): String {
        val target = digestHex.trim().lowercase()
        val algo = detectHashAlgorithm(target)
        val candidates = buildList {
            if (customCandidatesText.isNotBlank()) {
                customCandidatesText.split(Regex("[\\r\\n,]+"))
                    .map { it.trim() }
                    .filter { it.isNotEmpty() }
                    .forEach { add(it) }
            }
            addAll(defaultWordlist)
        }.distinct()

        val startNs = System.nanoTime()
        var attempts = 0
        var matchedSecret: String? = null

        for (cand in candidates) {
            attempts++
            val md = MessageDigest.getInstance(algo)
            val digestBytes = md.digest(cand.toByteArray(StandardCharsets.UTF_8))
            val hex = digestBytes.joinToString("") { "%02x".format(it) }
            if (hex == target) {
                matchedSecret = cand
                break
            }
        }

        val elapsedMs = (System.nanoTime() - startNs) / 1_000_000.0
        return buildString {
            appendLine("=== HASH CRACKER REPORT ===")
            appendLine("Algorytm: $algo")
            appendLine("Cel: $target")
            appendLine("Status: ${if (matchedSecret != null) "CRACKED" else "NOT_FOUND"}")
            if (matchedSecret != null) {
                appendLine("Hasło: $matchedSecret")
            }
            appendLine("Liczba prób: $attempts")
            appendLine("Czas: ${"%.3f".format(elapsedMs)} ms")
        }
    }

    data class PmkidEntry(
        val pmkidHex: String,
        val apMacHex: String,
        val clientMacHex: String,
        val essidHex: String,
        val essidBytes: ByteArray,
        val essidLabel: String
    )

    fun parseWpa01Line(line: String): PmkidEntry {
        val parts = line.trim().split("*")
        require(parts.size >= 6 && parts[0] == "WPA" && parts[1] == "01") {
            "Wymagany format: WPA*01*<PMKID>*<AP_MAC>*<CLIENT_MAC>*<ESSID_HEX>"
        }
        val pmkid = parts[2].trim().lowercase()
        val apMac = parts[3].trim().lowercase()
        val clientMac = parts[4].trim().lowercase()
        val essidHex = parts[5].trim().lowercase()

        require(pmkid.length == 32 && pmkid.matches(Regex("^[0-9a-f]{32}$"))) { "PMKID musi mieć 32 znaki hex." }
        require(apMac.length == 12 && apMac.matches(Regex("^[0-9a-f]{12}$"))) { "AP_MAC musi mieć 12 znaków hex." }
        require(clientMac.length == 12 && clientMac.matches(Regex("^[0-9a-f]{12}$"))) { "CLIENT_MAC musi mieć 12 znaków hex." }
        require(essidHex.isNotEmpty() && essidHex.length % 2 == 0 && essidHex.matches(Regex("^[0-9a-f]+$"))) {
            "ESSID_HEX musi być poprawnym ciągiem hex."
        }

        val essidBytes = hexToBytes(essidHex)
        val essidLabel = String(essidBytes, StandardCharsets.UTF_8)
        return PmkidEntry(pmkid, apMac, clientMac, essidHex, essidBytes, essidLabel)
    }

    fun computePmkid(passphrase: String, entry: PmkidEntry): String {
        val spec = PBEKeySpec(passphrase.toCharArray(), entry.essidBytes, 4096, 256)
        val skf = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA1")
        val pmk = skf.generateSecret(spec).encoded

        val mac = Mac.getInstance("HmacSHA1").apply {
            init(SecretKeySpec(pmk, "HmacSHA1"))
        }
        val msg = "PMK Name".toByteArray(StandardCharsets.US_ASCII) +
            hexToBytes(entry.apMacHex) +
            hexToBytes(entry.clientMacHex)
        val digest = mac.doFinal(msg)
        return digest.copyOfRange(0, 16).joinToString("") { "%02x".format(it) }
    }

    fun auditPmkid(wpa01Line: String, customPassphrasesText: String = ""): String {
        val entry = parseWpa01Line(wpa01Line)
        val candidates = buildList {
            if (customPassphrasesText.isNotBlank()) {
                customPassphrasesText.split(Regex("[\\r\\n,]+"))
                    .map { it.trim() }
                    .filter { it.isNotEmpty() }
                    .forEach { add(it) }
            }
            addAll(defaultWordlist)
        }.distinct()

        val startNs = System.nanoTime()
        var attempts = 0
        var matched: String? = null

        for (secret in candidates) {
            attempts++
            val calc = computePmkid(secret, entry)
            if (calc == entry.pmkidHex) {
                matched = secret
                break
            }
        }

        val elapsedMs = (System.nanoTime() - startNs) / 1_000_000.0
        return buildString {
            appendLine("=== PMKID AUDIT REPORT ===")
            appendLine("ESSID: ${entry.essidLabel} (${entry.essidHex})")
            appendLine("AP MAC: ${entry.apMacHex} | Client MAC: ${entry.clientMacHex}")
            appendLine("Docelowy PMKID: ${entry.pmkidHex}")
            appendLine("Status: ${if (matched != null) "MATCHED" else "NO_MATCH"}")
            if (matched != null) {
                appendLine("Dopasowane hasło: $matched")
            }
            appendLine("Liczba prób: $attempts")
            appendLine("Czas: ${"%.2f".format(elapsedMs)} ms")
        }
    }

    private fun hexToBytes(hex: String): ByteArray {
        val out = ByteArray(hex.length / 2)
        var i = 0
        while (i < hex.length) {
            out[i / 2] = ((Character.digit(hex[i], 16) shl 4) + Character.digit(hex[i + 1], 16)).toByte()
            i += 2
        }
        return out
    }

    private fun readStreamSafe(stream: InputStream?, maxBytes: Int): String {
        if (stream == null) return ""
        return stream.use { input ->
            BufferedReader(InputStreamReader(input, StandardCharsets.UTF_8)).use { reader ->
                val sb = StringBuilder()
                val buf = CharArray(1024)
                var total = 0
                while (total < maxBytes) {
                    val read = reader.read(buf, 0, minOf(buf.size, maxBytes - total))
                    if (read <= 0) break
                    sb.append(buf, 0, read)
                    total += read
                }
                sb.toString()
            }
        }
    }
}
