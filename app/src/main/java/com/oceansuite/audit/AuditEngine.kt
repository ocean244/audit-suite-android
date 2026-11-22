package com.oceansuite.audit

import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Locale
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec
import kotlin.math.ln

object AuditEngine {

    private val COMMON_WORDS = listOf(
        "password", "123456", "12345678", "123456789", "qwerty", "abc123",
        "admin", "letmein", "monkey", "dragon", "111111", "baseball",
        "iloveyou", "trustno1", "sunshine", "master", "welcome", "shadow",
        "ashley", "football", "jesus", "michael", "ninja", "mustang",
        "password1", "12345", "123123", "admin123", "root", "toor",
        "pass", "guest", "test", "changeme", "default", "superman",
        "qazwsx", "1234", "1234567", "000000", "666666", "777777",
        "888888", "999999", "zaq12wsx", "freedom", "starwars", "whatever",
        "polska", "polska123", "qwerty123", "haslo", "haslo123", "administrator",
        "superuser", "changeme123", "solar", "wifi1234", "internet123", "router123"
    )

    private val PANEL_PATHS = listOf(
        "/admin", "/administrator", "/wp-admin", "/login", "/phpmyadmin",
        "/adminer.php", "/.git/HEAD", "/.env", "/actuator", "/actuator/env",
        "/debug", "/server-status", "/config", "/swagger", "/manager/html",
        "/.well-known", "/api", "/api/v1", "/graphql", "/console", "/dashboard",
        "/cpanel", "/webmail", "/pma", "/dbadmin", "/backup", "/backups",
        "/old", "/temp", "/tmp", "/test", "/staging", "/dev", "/robots.txt",
        "/sitemap.xml", "/crossdomain.xml", "/clientaccesspolicy.xml",
        "/.DS_Store", "/.htaccess", "/.htpasswd", "/web.config", "/config.php",
        "/settings.php", "/wp-config.php", "/info.php", "/phpinfo.php",
        "/metrics", "/health", "/status", "/trace", "/heapdump", "/env"
    )

    fun bucketPermutations(brandInput: String): List<String> {
        val clean = brandInput.trim().lowercase(Locale.ROOT)
            .replace(Regex("^https?://"), "")
            .replace(Regex("\\.s3\\.amazonaws\\.com.*$"), "")
            .replace(Regex("[^a-z0-9-]"), "-")
            .trim('-')
        if (clean.isEmpty()) return emptyList()
        val suffixes = listOf("", "-assets", "-backups", "-dev", "-media", "-static", "-uploads", "-prod", "-public")
        return suffixes.map { "${clean}${it}" }.distinct()
    }

    fun runBucketBuster(brandInput: String, owned: Boolean): String {
        if (!owned) return "BLAD: Wymagane potwierdzenie 'I own this bucket / brand'."
        val candidates = bucketPermutations(brandInput)
        if (candidates.isEmpty()) return "BLAD: Podaj poprawna nazwe marki lub bucketa."
        val sb = StringBuilder()
        sb.append("=== BUCKET BUSTER REPORT ===\n")
        sb.append("Marka/Cel: ${brandInput.trim()}\n")
        sb.append("Permutacje (${candidates.size}): ${candidates.joinToString(", ")}\n")
        var publicCount = 0
        for (name in candidates) {
            val s3Url = "https://$name.s3.amazonaws.com/?list-type=2"
            val s3Resp = httpGet(s3Url)
            if (s3Resp != null && s3Resp.code == 200 && s3Resp.body.contains("<Key>")) {
                publicCount++
                val keys = Regex("<Key>([^<]+)</Key>").findAll(s3Resp.body).map { it.groupValues[1] }.take(25).toList()
                sb.append("[S3 PUBLIC] $name ($s3Url) -> obiektow: ${keys.size}\n")
                keys.forEach { k ->
                    val encKey = URLEncoder.encode(k, StandardCharsets.UTF_8.name()).replace("+", "%20")
                    sb.append("  * $k -> https://$name.s3.amazonaws.com/$encKey\n")
                }
            }
            val gcsUrl = "https://storage.googleapis.com/storage/v1/b/$name/o"
            val gcsResp = httpGet(gcsUrl)
            if (gcsResp != null && gcsResp.code == 200 && gcsResp.body.contains("\"name\"")) {
                publicCount++
                val objs = Regex("\"name\"\\s*:\\s*\"([^\"]+)\"").findAll(gcsResp.body).map { it.groupValues[1] }.take(25).toList()
                sb.append("[GCS PUBLIC] $name ($gcsUrl) -> obiektow: ${objs.size}\n")
                objs.forEach { o ->
                    val encObj = URLEncoder.encode(o, StandardCharsets.UTF_8.name()).replace("+", "%20")
                    sb.append("  * $o -> https://storage.googleapis.com/storage/v1/b/$name/o/$encObj\n")
                }
            }
        }
        if (publicCount == 0) {
            sb.append("Brak publicznych bucketow z otwartym listingiem dla podanej marki.\n")
        }
        sb.append("Obrona: Wlacz Block Public Access (S3) / Uniform Bucket-Level Access (GCS) i wylacz anonimowy listing.\n")
        return sb.toString()
    }

    fun generateLookalikes(domainInput: String): List<String> {
        val base = domainInput.trim().lowercase(Locale.ROOT)
            .replace(Regex("^https?://"), "")
            .substringBefore("/")
        if (!base.contains(".")) return emptyList()
        val parts = base.split(".", limit = 2)
        val label = parts[0]
        val tld = parts[1]
        val out = LinkedHashSet<String>()
        out.add(base)
        if (label.contains("m")) out.add("${label.replace("m", "rn")}.$tld")
        if (label.contains("rn")) out.add("${label.replace("rn", "m")}.$tld")
        if (label.contains("o")) out.add("${label.replace("o", "0")}.$tld")
        if (label.contains("0")) out.add("${label.replace("0", "o")}.$tld")
        if (label.contains("l")) out.add("${label.replace("l", "1")}.$tld")
        if (label.contains("i")) out.add("${label.replace("i", "1")}.$tld")
        if (label.contains("w")) out.add("${label.replace("w", "vv")}.$tld")
        for (i in label.indices) {
            out.add("${label.removeRange(i, i + 1)}.$tld")
            out.add("${label.substring(0, i + 1)}${label[i]}${label.substring(i + 1)}.$tld")
        }
        for (altTld in listOf("com", "co", "net", "org", "io", "pl", "eu")) {
            if (altTld != tld) out.add("$label.$altTld")
        }
        return out.take(40).toList()
    }

    fun runDoppelganger(domainInput: String): String {
        val cleanRoot = domainInput.trim().lowercase(Locale.ROOT)
            .replace(Regex("^https?://"), "")
            .substringBefore("/")
        val candidates = generateLookalikes(cleanRoot)
        if (candidates.isEmpty()) return "BLAD: Podaj poprawna domene (np. przyklad.pl)."
        val spfTxt = httpGet("https://dns.google/resolve?name=$cleanRoot&type=TXT")?.body ?: ""
        val dmarcTxt = httpGet("https://dns.google/resolve?name=_dmarc.$cleanRoot&type=TXT")?.body ?: ""
        val caaResp = httpGet("https://dns.google/resolve?name=$cleanRoot&type=CAA")?.body ?: ""
        val hasSpf = spfTxt.contains("v=spf1", ignoreCase = true)
        val hasDmarc = dmarcTxt.contains("v=dmarc1", ignoreCase = true)
        val hasCaa = caaResp.contains("\"data\"")

        val sb = StringBuilder()
        sb.append("=== DOPPELGANGER & DNS POSTURE RADAR ===\n")
        sb.append("Domena bazowa: $cleanRoot\n")
        sb.append("Polityka DNS: SPF=${if (hasSpf) "OK" else "BRAK"} | DMARC=${if (hasDmarc) "OK" else "BRAK"} | CAA=${if (hasCaa) "OK" else "BRAK"}\n")
        var regCount = 0
        var mxCount = 0
        for (cand in candidates) {
            val aJson = httpGet("https://dns.google/resolve?name=$cand&type=A")?.body ?: ""
            val mxJson = httpGet("https://dns.google/resolve?name=$cand&type=MX")?.body ?: ""
            val hasA = aJson.contains("\"data\"")
            val hasMx = mxJson.contains("\"data\"")
            val status = if (hasA && hasMx) {
                regCount++
                mxCount++
                "PULSUJACY [ZAREJESTROWANY + MX]"
            } else if (hasA) {
                regCount++
                "CZERWONY [ZAREJESTROWANY]"
            } else {
                "SZARY [NIEZAREJESTROWANY]"
            }
            sb.append("$cand -> $status\n")
        }
        sb.append("Podsumowanie: zarejestrowane=$regCount, z MX=$mxCount, sprawdzone=${candidates.size}\n")
        sb.append("Obrona: Utrzymuj rekordy SPF/DMARC/CAA, monitoruj podobne domeny i rejestruj krytyczne warianty.\n")
        return sb.toString()
    }

    fun detectHashAlgo(hashInput: String): String {
        return when (hashInput.trim().length) {
            32 -> "MD5 (128-bit)"
            40 -> "SHA-1 (160-bit)"
            64 -> "SHA-256 (256-bit)"
            else -> "Nieznany / nieobslugiwana dlugosc"
        }
    }

    fun crackHash(hashInput: String, candidatesRaw: String, owned: Boolean): String {
        if (!owned) return "BLAD: Wymagane potwierdzenie 'I own this hash'."
        val target = hashInput.trim().lowercase(Locale.ROOT)
        val algo = when (target.length) {
            32 -> "MD5"
            40 -> "SHA-1"
            64 -> "SHA-256"
            else -> return "BLAD: Nieobslugiwana dlugosc skrotu (${target.length}). Obslugiwane: 32 (MD5), 40 (SHA1), 64 (SHA256)."
        }
        val customWords = candidatesRaw.split(Regex("[\\r\\n,]+")).map { it.trim() }.filter { it.isNotEmpty() }
        val pool = (customWords + COMMON_WORDS).distinct()
        val startNs = System.nanoTime()
        var attempts = 0
        for (word in pool) {
            attempts++
            if (digestHex(algo, word) == target) {
                val elapsedMs = (System.nanoTime() - startNs) / 1_000_000.0
                return "=== HASH CRACKER REPORT ===\nAlgorytm: $algo\nCel: $target\nStatus: CRACKED: $word\nLiczba prob: $attempts\nCzas: ${String.format(Locale.US, "%.3f", elapsedMs)} ms\nObrona: Stosuj wolne haszowanie z sola (Argon2id / bcrypt) oraz dlugie unikalne hasla."
            }
        }
        val elapsedMs = (System.nanoTime() - startNs) / 1_000_000.0
        return "=== HASH CRACKER REPORT ===\nAlgorytm: $algo\nCel: $target\nStatus: NOT FOUND\nLiczba prob: $attempts\nCzas: ${String.format(Locale.US, "%.3f", elapsedMs)} ms\nObrona: Stosuj wolne haszowanie z sola (Argon2id / bcrypt) oraz dlugie unikalne hasla."
    }

    fun runAttackSurface(domainInput: String): String {
        val cleanDomain = domainInput.trim()
            .replace(Regex("^https?://"), "")
            .substringBefore("/")
        if (cleanDomain.isEmpty()) return "BLAD: Podaj domene (np. przyklad.pl)."
        val baseUrl = "https://$cleanDomain"
        val homeResp = httpGet(baseUrl)
        val notFoundBody = httpGet("$baseUrl/nonexistent-ocean-probe-404-check")?.body ?: ""
        val openPanels = mutableListOf<String>()
        for (p in PANEL_PATHS) {
            val r = httpGet("$baseUrl$p")
            if (r != null && r.code in 200..299 && r.body.isNotEmpty() && r.body != notFoundBody) {
                openPanels.add("$p (HTTP ${r.code})")
            }
        }
        val logPaths = listOf("/logs/app.log", "/log/error.log", "/storage/logs/laravel.log", "/var/log/syslog")
        val logHits = mutableListOf<String>()
        for (lp in logPaths) {
            val r = httpGet("$baseUrl$lp")
            if (r != null && r.code in 200..299 && r.body.isNotEmpty()) {
                val emails = Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}").findAll(r.body).count()
                val tokens = Regex("(token|api[_-]?key|secret|bearer)[=: ]+[A-Za-z0-9._-]{8,}", RegexOption.IGNORE_CASE).findAll(r.body).count()
                if (emails > 0 || tokens > 0) {
                    logHits.add("$lp -> tokens=$tokens, emails=$emails")
                }
            }
        }
        val keyPaths = listOf(
            "/.ssh/id_rsa", "/server.key", "/private.key", "/privkey.pem",
            "/.ssh/id_ed25519", "/key.pem", "/ssl/private.key", "/id_rsa"
        )
        val keyHits = mutableListOf<String>()
        for (kp in keyPaths) {
            val r = httpGet("$baseUrl$kp")
            if (r != null && r.code in 200..299 && r.body.contains("-----BEGIN") && r.body.contains("PRIVATE KEY-----")) {
                val masked = r.body.take(12) + "..." + r.body.takeLast(8)
                keyHits.add("CAPTURED $kp -> $masked")
            }
        }
        val secHeaders = homeResp?.secHeaders ?: "Brak danych HTTP"
        val missingCount = secHeaders.split(",").count { it.contains("BRAK") }
        val totalLoot = openPanels.size + logHits.size + keyHits.size
        val modulesWithHits = listOf(openPanels.isNotEmpty(), logHits.isNotEmpty(), keyHits.isNotEmpty()).count { it }
        val severity = when {
            modulesWithHits == 3 -> "CRITICAL: FULL ATTACK SURFACE EXPOSED"
            totalLoot > 0 || missingCount >= 3 -> "EXPOSED"
            else -> "CLEAN"
        }
        return buildString {
            append("=== ATTACK SURFACE & HEADER AUDIT ===\n")
            append("Cel: $cleanDomain | EXPOSURE: $severity | Loot: $totalLoot | Brakujace naglowki: $missingCount\n")
            append("[Naglowki HTTP] $secHeaders\n")
            append("[Karta 1: Panels (${openPanels.size}/${PANEL_PATHS.size})] ${if (openPanels.isEmpty()) "Brak otwartych paneli" else openPanels.joinToString("; ")}\n")
            append("  Obrona: Uwierzytelnianie, ograniczenie IP i usuwanie nieuzywanych endpointow.\n")
            append("[Karta 2: Logs (${logHits.size})] ${if (logHits.isEmpty()) "Brak wyciekow w logach" else logHits.joinToString("; ")}\n")
            append("  Obrona: Nie udostepniaj logow w katalogu web, rotuj logi i maskuj sekrety.\n")
            append("[Karta 3: Keys (${keyHits.size})] ${if (keyHits.isEmpty()) "Brak kluczy prywatnych" else keyHits.joinToString("; ")}\n")
            append("  Obrona: Trzymaj klucze poza web root, stosuj chmod 600 i rotuj klucze przy ekspozycji.\n")
        }
    }

    fun scanFirmwareBytes(bytes: ByteArray, label: String): String {
        if (bytes.isEmpty()) return "BLAD: Pusty plik binarny lub brak dostepu do odczytu."
        val asciiStrings = extractAsciiStrings(bytes, 4)
        val utf16Strings = extractUtf16LeStrings(bytes, 4)
        val combined = asciiStrings + utf16Strings
        val patterns = listOf(
            "AWS_KEY" to Regex("AKIA[0-9A-Z]{16}"),
            "GOOGLE_API" to Regex("AIza[0-9A-Za-z_-]{35}"),
            "STRIPE_KEY" to Regex("(sk_live|sk_test)[0-9A-Za-z_]{8,}"),
            "PRIVATE_KEY" to Regex("-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
            "CREDENTIAL_ASSIGN" to Regex("(password|pwd|passwd)\\s*=\\s*[^\\s\"';]+", RegexOption.IGNORE_CASE),
            "JWT" to Regex("eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{4,}")
        )
        val findings = LinkedHashSet<String>()
        for (str in combined) {
            for ((kind, rx) in patterns) {
                for (m in rx.findAll(str)) {
                    val raw = m.value
                    val masked = if (raw.length >= 4) raw.take(4) + "*".repeat(minOf(12, raw.length - 4)) else "****"
                    val offset = bytes.indexOfSubarray(raw.toByteArray(StandardCharsets.UTF_8))
                    findings.add("$kind @ offset=$offset -> $masked")
                }
            }
            if (str.length > 16 && shannonEntropy(str) > 4.0) {
                val masked = str.take(4) + "*".repeat(10)
                val offset = bytes.indexOfSubarray(str.toByteArray(StandardCharsets.UTF_8))
                findings.add("HIGH_ENTROPY(${String.format(Locale.US, "%.2f", shannonEntropy(str))}) @ offset=$offset -> $masked")
            }
        }
        val hexStrip = bytes.take(64).joinToString(" ") { String.format(Locale.US, "%02X", it.toInt() and 0xFF) }
        return buildString {
            append("=== FIRMWARE SECRET LOOTER ===\n")
            append("Plik: $label (${bytes.size} B) | ASCII=${asciiStrings.size}, UTF16LE=${utf16Strings.size}\n")
            append("HEX[0..63]: $hexStrip\n")
            append("Znaleziska (${findings.size}):\n")
            if (findings.isEmpty()) {
                append("Brak dopasowan sekretow (stan pusty / czysty).\n")
            } else {
                findings.take(50).forEach { append("  * $it\n") }
            }
            append("Obrona: Nie umieszczaj poswiadczen na sztywno; uzywaj secure element, Android Keystore lub sekretow per-device.\n")
        }
    }

    fun buildKeystrokeVbs(typeLine: String, delayMs: Int, specialKey: String): String {
        val safeDelay = delayMs.coerceIn(50, 60000)
        val safeText = typeLine.replace("\"", "\"\"")
        val keyCmd = when (specialKey.uppercase(Locale.ROOT)) {
            "ENTER" -> "WshShell.SendKeys \"{ENTER}\""
            "TAB" -> "WshShell.SendKeys \"{TAB}\""
            "WIN+R" -> "WshShell.SendKeys \"^{ESC}\""
            "CTRL+C" -> "WshShell.SendKeys \"^c\""
            "CTRL+V" -> "WshShell.SendKeys \"^v\""
            "CTRL+A" -> "WshShell.SendKeys \"^a\""
            else -> "WshShell.SendKeys \"{ENTER}\""
        }
        return buildString {
            append("' ==== LAB ONLY - authorised testing on your own machine ====\n")
            append("WScript.Echo \"LAB ONLY\"\n")
            append("Set WshShell = CreateObject(\"WScript.Shell\")\n")
            append("WScript.Sleep $safeDelay\n")
            append("WshShell.SendKeys \"$safeText\"\n")
            append("WScript.Sleep $safeDelay\n")
            append("$keyCmd\n")
            append("' Obrona: Wylacz Windows Script Host, blokuj .vbs, stosuj AppLocker/WDAC oraz zasady HID przy blokadzie ekranu.\n")
        }
    }

    fun crackPmkid22000(lineInput: String, owned: Boolean, customWordsRaw: String): String {
        if (!owned) return "BLAD: Wymagane potwierdzenie 'I own this network'."
        val parts = lineInput.trim().split("*")
        if (parts.size < 6 || !parts[0].equals("WPA", ignoreCase = true) || parts[1] != "01") {
            return "BLAD: Niepoprawny format 22000. Oczekiwano: WPA*01*<pmkid_hex>*<ap_mac_hex>*<sta_mac_hex>*<essid_hex>***"
        }
        val targetPmkid = hexToBytes(parts[2])
        val apMac = hexToBytes(parts[3])
        val staMac = hexToBytes(parts[4])
        val essidBytes = hexToBytes(parts[5])
        if (targetPmkid.size != 16 || apMac.size != 6 || staMac.size != 6 || essidBytes.isEmpty()) {
            return "BLAD: Nieprawidlowe dlugosci pol PMKID (16B), AP MAC (6B), STA MAC (6B) lub ESSID."
        }
        val essidName = String(essidBytes, StandardCharsets.UTF_8)
        val custom = customWordsRaw.split(Regex("[\\r\\n,]+")).map { it.trim() }.filter { it.length in 8..63 }
        val wordlist = (custom + COMMON_WORDS.filter { it.length in 8..63 }).distinct()
        val pmkNamePrefix = "PMK Name".toByteArray(StandardCharsets.US_ASCII)
        val msg = pmkNamePrefix + apMac + staMac
        var attempts = 0
        for (pass in wordlist) {
            attempts++
            val pmk = pbkdf2Sha1(pass, essidBytes, 4096, 256)
            val cand = hmacSha1(pmk, msg).copyOf(16)
            if (cand.contentEquals(targetPmkid)) {
                return "=== PMKID SNATCHER ===\nAUTHORIZED TESTING - YOUR OWN NETWORK ONLY\nCapture the PMKID from your own router with a monitor-mode adapter and hcxdumptool, then paste it here to crack it.\nPASSWORD CRACKED: $pass\nESSID: $essidName\nProby: $attempts\nObrona: Uzywaj dlugiego losowego hasla WPA2 lub WPA3."
            }
        }
        return "=== PMKID SNATCHER ===\nAUTHORIZED TESTING - YOUR OWN NETWORK ONLY\nCapture the PMKID from your own router with a monitor-mode adapter and hcxdumptool, then paste it here to crack it.\npassword not in wordlist (proby: $attempts, ESSID: $essidName)\nObrona: Uzywaj dlugiego losowego hasla WPA2 lub WPA3."
    }

    private fun digestHex(algo: String, input: String): String {
        val md = MessageDigest.getInstance(algo)
        val out = md.digest(input.toByteArray(StandardCharsets.UTF_8))
        return out.joinToString("") { String.format(Locale.US, "%02x", it.toInt() and 0xFF) }
    }

    private fun pbkdf2Sha1(password: String, salt: ByteArray, iterations: Int, bits: Int): ByteArray {
        val spec = PBEKeySpec(password.toCharArray(), salt, iterations, bits)
        val skf = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA1")
        return skf.generateSecret(spec).encoded
    }

    private fun hmacSha1(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA1")
        mac.init(SecretKeySpec(key, "HmacSHA1"))
        return mac.doFinal(data)
    }

    private fun hexToBytes(hex: String): ByteArray {
        val clean = hex.trim()
        if (clean.length % 2 != 0 || !clean.matches(Regex("^[0-9a-fA-F]+$"))) return ByteArray(0)
        return ByteArray(clean.length / 2) { i ->
            clean.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
    }

    private fun extractAsciiStrings(bytes: ByteArray, minLen: Int): List<String> {
        val res = mutableListOf<String>()
        val sb = StringBuilder()
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            if (v in 32..126) {
                sb.append(v.toChar())
            } else {
                if (sb.length >= minLen) res.add(sb.toString())
                sb.setLength(0)
            }
        }
        if (sb.length >= minLen) res.add(sb.toString())
        return res
    }

    private fun extractUtf16LeStrings(bytes: ByteArray, minLen: Int): List<String> {
        val res = mutableListOf<String>()
        val sb = StringBuilder()
        var i = 0
        while (i + 1 < bytes.size) {
            val lo = bytes[i].toInt() and 0xFF
            val hi = bytes[i + 1].toInt() and 0xFF
            if (hi == 0 && lo in 32..126) {
                sb.append(lo.toChar())
            } else {
                if (sb.length >= minLen) res.add(sb.toString())
                sb.setLength(0)
            }
            i += 2
        }
        if (sb.length >= minLen) res.add(sb.toString())
        return res
    }

    private fun shannonEntropy(text: String): Double {
        if (text.isEmpty()) return 0.0
        val counts = HashMap<Char, Int>()
        for (c in text) counts[c] = (counts[c] ?: 0) + 1
        val len = text.length.toDouble()
        var ent = 0.0
        for (cnt in counts.values) {
            val p = cnt.toDouble() / len
            ent -= p * (ln(p) / ln(2.0))
        }
        return ent
    }

    private fun ByteArray.indexOfSubarray(needle: ByteArray): Int {
        if (needle.isEmpty() || needle.size > this.size) return -1
        for (i in 0..(this.size - needle.size)) {
            var ok = true
            for (j in needle.indices) {
                if (this[i + j] != needle[j]) {
                    ok = false
                    break
                }
            }
            if (ok) return i
        }
        return -1
    }

    private data class HttpResult(val code: Int, val body: String, val secHeaders: String)

    private fun httpGet(urlStr: String): HttpResult? {
        return try {
            val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 4000
                readTimeout = 4000
                instanceFollowRedirects = true
                setRequestProperty("User-Agent", "OceanAuditSuite/2.0")
            }
            val code = conn.responseCode
            val hsts = if (!conn.getHeaderField("Strict-Transport-Security").isNullOrBlank()) "HSTS=OK" else "HSTS=BRAK"
            val csp = if (!conn.getHeaderField("Content-Security-Policy").isNullOrBlank()) "CSP=OK" else "CSP=BRAK"
            val xfo = if (!conn.getHeaderField("X-Frame-Options").isNullOrBlank()) "XFO=OK" else "XFO=BRAK"
            val xcto = if (!conn.getHeaderField("X-Content-Type-Options").isNullOrBlank()) "XCTO=OK" else "XCTO=BRAK"
            val srv = conn.getHeaderField("Server") ?: "ukryty"
            val xpb = conn.getHeaderField("X-Powered-By") ?: "ukryty"
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val body = stream?.bufferedReader()?.use { it.readText() } ?: ""
            conn.disconnect()
            HttpResult(code, body, "$hsts, $csp, $xfo, $xcto, Server=$srv, X-Powered-By=$xpb")
        } catch (_: Exception) {
            null
        }
    }
}
