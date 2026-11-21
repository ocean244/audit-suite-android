#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
PKG_PATH="${PROJECT_DIR}/app/src/main/java/com/oceansuite/audit"
ENGINE_FILE="${PKG_PATH}/AuditEngine.kt"
MAIN_FILE="${PKG_PATH}/MainActivity.kt"
GRADLE_PROPS="${PROJECT_DIR}/gradle.properties"
LOCAL_PROPS="${PROJECT_DIR}/local.properties"
DIST_APK="${PROJECT_DIR}/dist/app-debug.apk"
DOWNLOAD_APK="/sdcard/Download/OceanAuditSuite.apk"
INTERNAL_DIR="/sdcard/OceanAuditSuite"
INTERNAL_APK="${INTERNAL_DIR}/OceanAuditSuite.apk"
STATUS_FILE="${INTERNAL_DIR}/vector_status.txt"
RELEASE_LOG="${INTERNAL_DIR}/full_7_suite_release.txt"
DAEMON_PID_FILE="${PROJECT_DIR}/state/daemon.pid"
PKG_NAME="com.oceansuite.audit"
ACTIVITY_NAME="com.oceansuite.audit/.MainActivity"
DEFAULT_ADB_TARGET="192.168.1.157:42079"
NATIVE_AAPT2="/data/data/com.termux/files/usr/bin/aapt2"
GH_OWNER="ocean244"
GH_REPO="audit-suite-android"
TOKEN_FILE="${HOME}/.gh_token"

resolve_gh_token() {
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN"
  elif [ -f "$TOKEN_FILE" ]; then
    tr -d '[:space:]' < "$TOKEN_FILE"
  else
    printf ''
  fi
}

mkdir -p "$PKG_PATH" "$(dirname "$DIST_APK")" "$INTERNAL_DIR"

SDK_DIR="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/android-sdk}}"
[ -d "$SDK_DIR" ] || { echo "BŁĄD: Brak katalogu Android SDK ($SDK_DIR)" >&2; exit 1; }
[ -x "$NATIVE_AAPT2" ] || { echo "BŁĄD: Brak natywnego aapt2 ($NATIVE_AAPT2)" >&2; exit 1; }

printf 'sdk.dir=%s\n' "$SDK_DIR" > "$LOCAL_PROPS"
touch "$GRADLE_PROPS"
python3 - "$GRADLE_PROPS" "$NATIVE_AAPT2" << 'PYEOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
aapt2 = sys.argv[2]
lines = [ln for ln in p.read_text(encoding="utf-8").splitlines(keepends=True) if not ln.startswith("android.aapt2FromMavenOverride=")]
lines.append(f"android.aapt2FromMavenOverride={aapt2}\n")
p.write_text("".join(lines), encoding="utf-8")
PYEOF

cat << 'KTEOF' > "$ENGINE_FILE"
package com.oceansuite.audit

import java.net.HttpURLConnection
import java.net.URL
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
        "888888", "999999", "zaq12wsx", "freedom", "starwars", "whatever"
    )

    fun bucketPermutations(brandInput: String): List<String> {
        val clean = brandInput.trim().lowercase(Locale.ROOT)
            .replace(Regex("^https?://"), "")
            .replace(Regex("\\.s3\\.amazonaws\\.com.*$"), "")
            .replace(Regex("[^a-z0-9-]"), "-")
            .trim('-')
        if (clean.isEmpty()) return emptyList()
        val suffixes = listOf("", "-assets", "-backups", "-dev", "-media", "-static", "-uploads")
        return suffixes.map { "${clean}${it}" }.distinct()
    }

    fun runBucketBuster(brandInput: String, owned: Boolean): String {
        if (!owned) return "BŁĄD: Wymagane potwierdzenie 'I own this bucket / brand'."
        val candidates = bucketPermutations(brandInput)
        if (candidates.isEmpty()) return "BŁĄD: Podaj poprawną nazwę marki lub bucketa."
        val sb = StringBuilder()
        sb.append("=== BUCKET BUSTER REPORT ===\n")
        sb.append("Marka/Cel: ${brandInput.trim()}\n")
        sb.append("Permutacje: ${candidates.joinToString(", ")}\n")
        var publicCount = 0
        for (name in candidates) {
            val s3Url = "https://$name.s3.amazonaws.com/?list-type=2"
            val s3Resp = httpGet(s3Url)
            if (s3Resp != null && s3Resp.code == 200 && s3Resp.body.contains("<Key>")) {
                publicCount++
                val keys = Regex("<Key>([^<]+)</Key>").findAll(s3Resp.body).map { it.groupValues[1] }.take(20).toList()
                sb.append("[S3 PUBLIC] $name ($s3Url) -> obiektów: ${keys.size}\n")
                keys.forEach { k -> sb.append("  * $k -> https://$name.s3.amazonaws.com/$k\n") }
            }
            val gcsUrl = "https://storage.googleapis.com/storage/v1/b/$name/o"
            val gcsResp = httpGet(gcsUrl)
            if (gcsResp != null && gcsResp.code == 200 && gcsResp.body.contains("\"name\"")) {
                publicCount++
                val objs = Regex("\"name\"\\s*:\\s*\"([^\"]+)\"").findAll(gcsResp.body).map { it.groupValues[1] }.take(20).toList()
                sb.append("[GCS PUBLIC] $name ($gcsUrl) -> obiektów: ${objs.size}\n")
                objs.forEach { o -> sb.append("  * $o -> https://storage.googleapis.com/storage/v1/b/$name/o/${o}\n") }
            }
        }
        if (publicCount == 0) {
            sb.append("Brak publicznych bucketów dla podanej marki.\n")
        }
        sb.append("Obrona: Włącz Block Public Access i wyłącz anonimowy listing.\n")
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
        for (altTld in listOf("com", "co", "net", "org", "io")) {
            out.add("$label.$altTld")
        }
        return out.take(36).toList()
    }

    fun runDoppelganger(domainInput: String): String {
        val candidates = generateLookalikes(domainInput)
        if (candidates.isEmpty()) return "BŁĄD: Podaj poprawną domenę (np. przyklad.pl)."
        val sb = StringBuilder()
        sb.append("=== DOPPELGANGER RADAR ===\n")
        sb.append("Autoryzowane rozpoznanie własnej domeny: ${domainInput.trim()}\n")
        var regCount = 0
        var mxCount = 0
        for (cand in candidates) {
            val aJson = httpGet("https://dns.google/resolve?name=$cand&type=A")?.body ?: ""
            val mxJson = httpGet("https://dns.google/resolve?name=$cand&type=MX")?.body ?: ""
            val hasA = aJson.contains("\"data\"")
            val hasMx = mxJson.contains("\"data\"")
            val status = when {
                hasA && hasMx -> { regCount++; mxCount++; "PULSUJĄCY [ZAREJESTROWANY + MX]" }
                hasA -> { regCount++; "CZERWONY [ZAREJESTROWANY]" }
                else -> "SZARY [NIEZAREJESTROWANY]" }
            }
            sb.append("$cand -> $status\n")
        }
        sb.append("Podsumowanie: zarejestrowane=$regCount, z MX=$mxCount, sprawdzone=${candidates.size}\n")
        sb.append("Obrona: Rejestruj kluczowe warianty, monitoruj logi CT i szkol personel.\n")
        return sb.toString()
    }

    fun crackHash(hashInput: String, candidatesRaw: String, owned: Boolean): String {
        if (!owned) return "BŁĄD: Wymagane potwierdzenie 'I own this hash'."
        val target = hashInput.trim().lowercase(Locale.ROOT)
        val algo = when (target.length) {
            32 -> "MD5"
            40 -> "SHA-1"
            64 -> "SHA-256"
            else -> return "BŁĄD: Nieobsługiwana długość skrótu (${target.length}). Obsługiwane: 32 (MD5), 40 (SHA1), 64 (SHA256)."
        }
        val customWords = candidatesRaw.split(Regex("[\\r\\n,]+")).map { it.trim() }.filter { it.isNotEmpty() }
        val pool = if (customWords.isNotEmpty()) customWords + COMMON_WORDS else COMMON_WORDS
        val startNs = System.nanoTime()
        var attempts = 0
        for (word in pool) {
            attempts++
            val digest = digestHex(algo, word)
            if (digest == target) {
                val elapsedMs = (System.nanoTime() - startNs) / 1_000_000.0
                return "=== HASH CRACKER REPORT ===\nAlgorytm: $algo\nCel: $target\nStatus: CRACKED: $word\nLiczba prób: $attempts\nCzas: ${String.format(Locale.US, "%.3f", elapsedMs)} ms\nObrona: Stosuj wolne haszowanie z solą (bcrypt / argon2) oraz długie unikalne hasła."
            }
        }
        val elapsedMs = (System.nanoTime() - startNs) / 1_000_000.0
        return "=== HASH CRACKER REPORT ===\nAlgorytm: $algo\nCel: $target\nStatus: NOT FOUND\nLiczba prób: $attempts\nCzas: ${String.format(Locale.US, "%.3f", elapsedMs)} ms\nObrona: Stosuj wolne haszowanie z solą (bcrypt / argon2) oraz długie unikalne hasła."
    }

    fun runAttackSurface(domainInput: String): String {
        val cleanDomain = domainInput.trim()
            .replace(Regex("^https?://"), "")
            .substringBefore("/")
        if (cleanDomain.isEmpty()) return "BŁĄD: Podaj własną domenę."
        val baseUrl = "https://$cleanDomain"
        val panelPaths = listOf(
            "/admin", "/administrator", "/wp-admin", "/login", "/phpmyadmin",
            "/adminer.php", "/.git/HEAD", "/.env", "/actuator", "/actuator/env",
            "/debug", "/server-status", "/config", "/swagger", "/manager/html", "/.well-known"
        )
        val notFoundBody = httpGet("$baseUrl/nonexistent-ocean-probe-404-check")?.body ?: ""
        val openPanels = mutableListOf<String>()
        for (p in panelPaths) {
            val r = httpGet("$baseUrl$p")
            if (r != null && r.code in 200..299 && r.body.isNotEmpty() && r.body != notFoundBody) {
                openPanels.add("$p (HTTP ${r.code})")
            }
        }
        val logPaths = listOf("/logs/app.log", "/log/error.log")
        val logHits = mutableListOf<String>()
        for (lp in logPaths) {
            val r = httpGet("$baseUrl$lp")
            if (r != null && r.code in 200..299 && r.body.isNotEmpty()) {
                val emails = Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}").findAll(r.body).count()
                val tokens = Regex("(token|api[_-]?key|secret|bearer)[=: ]+[A-Za-z0-9._-]{8,}", RegexOption.IGNORE_CASE).findAll(r.body).count()
                logHits.add("$lp -> tokens=$tokens, emails=$emails")
            }
        }
        val keyPaths = listOf(
            "/.ssh/id_rsa", "/server.key", "/private.key", "/privkey.pem",
            "/.ssh/id_ed25519", "/key.pem", "/ssl/private.key"
        )
        val keyHits = mutableListOf<String>()
        for (kp in keyPaths) {
            val r = httpGet("$baseUrl$kp")
            if (r != null && r.code in 200..299 && r.body.contains("-----BEGIN") && r.body.contains("PRIVATE KEY-----")) {
                val masked = r.body.take(12) + "..." + r.body.takeLast(8)
                keyHits.add("CAPTURED $kp -> $masked")
            }
        }
        val totalLoot = openPanels.size + logHits.size + keyHits.size
        val modulesWithHits = listOf(openPanels.isNotEmpty(), logHits.isNotEmpty(), keyHits.isNotEmpty()).count { it }
        val severity = when {
            modulesWithHits == 3 -> "CRITICAL: FULL ATTACK SURFACE EXPOSED"
            totalLoot > 0 -> "EXPOSED"
            else -> "CLEAN"
        }
        return buildString {
            append("=== ATTACK SURFACE SCANNER ===\n")
            append("EXPOSURE: $severity | Loot: $totalLoot\n")
            append("[Karta 1: Panels (${openPanels.size})] ${if (openPanels.isEmpty()) "Brak otwartych paneli" else openPanels.joinToString("; ")}\n")
            append("  Obrona: Uwierzytelnianie i usuwanie nieużywanych paneli.\n")
            append("[Karta 2: Logs (${logHits.size})] ${if (logHits.isEmpty()) "Brak wycieków w logach" else logHits.joinToString("; ")}\n")
            append("  Obrona: Nie udostępniaj logów w katalogu web i maskuj sekrety.\n")
            append("[Karta 3: Keys (${keyHits.size})] ${if (keyHits.isEmpty()) "Brak kluczy prywatnych" else keyHits.joinToString("; ")}\n")
            append("  Obrona: Trzymaj klucze poza web root i rotuj przy ekspozycji.\n")
        }
    }

    fun scanFirmwareBytes(bytes: ByteArray, label: String): String {
        if (bytes.isEmpty()) return "BŁĄD: Pusty plik binarny."
        val asciiStrings = extractAsciiStrings(bytes, 4)
        val utf16Strings = extractUtf16LeStrings(bytes, 4)
        val combined = asciiStrings + utf16Strings
        val patterns = listOf(
            "AWS_KEY" to Regex("AKIA[0-9A-Z]{16}"),
            "GOOGLE_API" to Regex("Alza[0-9A-Za-z_-]{35}"),
            "STRIPE_KEY" to Regex("(sk_live|sk_test)[0-9A-Za-z_]{8,}"),
            "PRIVATE_KEY" to Regex("-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
            "CREDENTIAL_ASSIGN" to Regex("(password|pwd|passwd)\\s*=\\s*[^\\s\"';]+", RegexOption.IGNORE_CASE),
            "JWT" to Regex("eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{4,}")
        )
        val findings = mutableListOf<String>()
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
                append("Brak dopasowań sekretów (stan pusty / czysty).\n")
            } else {
                findings.take(40).forEach { append("  * $it\n") }
            }
            append("Obrona: Nie umieszczaj poświadczeń na sztywno; używaj secure element lub sekretów per-device.\n")
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
            append("' Obrona: Wyłącz Windows Script Host, blokuj .vbs, stosuj AppLocker/WDAC oraz zasady HID przy blokadzie ekranu.\n")
        }
    }

    fun crackPmkid22000(lineInput: String, owned: Boolean, customWordsRaw: String): String {
        if (!owned) return "BŁĄD: Wymagane potwierdzenie 'I own this network'."
        val parts = lineInput.trim().split("*")
        if (parts.size < 6 || !parts[0].equals("WPA", ignoreCase = true) || parts[1] != "01") {
            return "BŁĄD: Niepoprawny format 22000. Oczekiwano: WPA*01*<pmkid_hex>*<ap_mac_hex>*<sta_mac_hex>*<essid_hex>***"
        }
        val targetPmkid = hexToBytes(parts[2])
        val apMac = hexToBytes(parts[3])
        val staMac = hexToBytes(parts[4])
        val essidBytes = hexToBytes(parts[5])
        if (targetPmkid.size != 16 || apMac.size != 6 || staMac.size != 6 || essidBytes.isEmpty()) {
            return "BŁĄD: Nieprawidłowe długości pól PMKID (16B), AP MAC (6B), STA MAC (6B) lub ESSID."
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
                return "=== PMKID SNATCHER ===\nAUTHORIZED TESTING - YOUR OWN NETWORK ONLY\nCapture the PMKID from your own router with a monitor-mode adapter and hcxdumptool, then paste it here to crack it.\nPASSWORD CRACKED: $pass\nESSID: $essidName\nPróby: $attempts\nObrona: Używaj długiego losowego hasła WPA2 lub WPA3."
            }
        }
        return "=== PMKID SNATCHER ===\nAUTHORIZED TESTING - YOUR OWN NETWORK ONLY\nCapture the PMKID from your own router with a monitor-mode adapter and hcxdumptool, then paste it here to crack it.\npassword not in wordlist (próby: $attempts, ESSID: $essidName)\nObrona: Używaj długiego losowego hasła WPA2 lub WPA3."
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

    private data class HttpResult(val code: Int, val body: String)

    private fun httpGet(urlStr: String): HttpResult? {
        return try {
            val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 3500
                readTimeout = 3500
                instanceFollowRedirects = true
                setRequestProperty("User-Agent", "OceanAuditSuite/1.0")
            }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val body = stream?.bufferedReader()?.use { it.readText() } ?: ""
            conn.disconnect()
            HttpResult(code, body)
        } catch (_: Exception) {
            null
        }
    }
}
KTEOF

cat << 'MAINEOF' > "$MAIN_FILE"
package com.oceansuite.audit

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize(), color = Color(0xFF0A0C0E)) {
                    OceanAuditSuiteScreen()
                }
            }
        }
    }
}

@Composable
fun OceanAuditSuiteScreen() {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val tabs = listOf("Bucket", "Doppelganger", "Hash", "Surface", "Firmware", "Keystroke", "PMKID")
    var activeTab by remember { mutableStateOf("Hash") }

    var brandInput by remember { mutableStateOf("") }
    var bucketOwned by remember { mutableStateOf(false) }

    var domainInput by remember { mutableStateOf("") }

    var hashInput by remember { mutableStateOf("5f4dcc3b5aa765d61d8327deb882cf99") }
    var candidatesInput by remember { mutableStateOf("password\nadmin\n123456") }
    var hashOwned by remember { mutableStateOf(true) }

    var surfaceDomain by remember { mutableStateOf("") }

    var firmwarePath by remember { mutableStateOf("/sdcard/OceanAuditSuite/OceanAuditSuite.apk") }

    var vbsLine by remember { mutableStateOf("echo LAB_ONLY_CHECK") }
    var vbsDelay by remember { mutableStateOf("500") }
    var vbsKey by remember { mutableStateOf("ENTER") }

    var pmkidLine by remember { mutableStateOf("") }
    var pmkidOwned by remember { mutableStateOf(false) }

    var outputText by remember { mutableStateOf("Gotowy do pracy.") }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Text("Ocean Audit Suite", color = Color(0xFF00E676), style = MaterialTheme.typography.headlineSmall)

        Row(
            modifier = Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            tabs.forEach { tab ->
                FilterChip(
                    selected = activeTab == tab,
                    onClick = { activeTab = tab },
                    label = { Text(tab) }
                )
            }
        }

        when (activeTab) {
            "Bucket" -> {
                OutlinedTextField(
                    value = brandInput,
                    onValueChange = { brandInput = it },
                    label = { Text("Własna marka lub bucket") },
                    modifier = Modifier.fillMaxWidth()
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = bucketOwned, onCheckedChange = { bucketOwned = it })
                    Text("I own this bucket / brand", color = Color.White)
                }
                Button(
                    onClick = {
                        scope.launch {
                            outputText = "Skanowanie S3/GCS..."
                            outputText = withContext(Dispatchers.IO) { AuditEngine.runBucketBuster(brandInput, bucketOwned) }
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFD32F2F)),
                    modifier = Modifier.fillMaxWidth()
                ) { Text("RAID", color = Color.White) }
            }

            "Doppelganger" -> {
                OutlinedTextField(
                    value = domainInput,
                    onValueChange = { domainInput = it },
                    label = { Text("Własna domena") },
                    modifier = Modifier.fillMaxWidth()
                )
                Button(
                    onClick = {
                        scope.launch {
                            outputText = "Sprawdzanie DNS A/MX..."
                            outputText = withContext(Dispatchers.IO) { AuditEngine.runDoppelganger(domainInput) }
                        }
                    },
                    modifier = Modifier.fillMaxWidth()
                ) { Text("Skanuj radar domen") }
            }

            "Hash" -> {
                val detected = when (hashInput.trim().length) {
                    32 -> "MD5"
                    40 -> "SHA1"
                    64 -> "SHA256"
                    else -> "Nieznany (${hashInput.trim().length})"
                }
                OutlinedTextField(
                    value = hashInput,
                    onValueChange = { hashInput = it },
                    label = { Text("Skrót HEX (MD5 / SHA1 / SHA256) — wykryto: $detected") },
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = candidatesInput,
                    onValueChange = { candidatesInput = it },
                    label = { Text("Kandydaci haseł (po jednym w linii lub po przecinku)") },
                    modifier = Modifier.fillMaxWidth()
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = hashOwned, onCheckedChange = { hashOwned = it })
                    Text("I own this hash", color = Color.White)
                }
                Button(
                    onClick = {
                        scope.launch {
                            outputText = withContext(Dispatchers.Default) {
                                AuditEngine.crackHash(hashInput, candidatesInput, hashOwned)
                            }
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFD32F2F)),
                    modifier = Modifier.fillMaxWidth()
                ) { Text("CRACK", color = Color.White) }
            }

            "Surface" -> {
                OutlinedTextField(
                    value = surfaceDomain,
                    onValueChange = { surfaceDomain = it },
                    label = { Text("Własna domena (Panels / Logs / Keys)") },
                    modifier = Modifier.fillMaxWidth()
                )
                Button(
                    onClick = {
                        scope.launch {
                            outputText = "Skanowanie paneli, logów i kluczy..."
                            outputText = withContext(Dispatchers.IO) { AuditEngine.runAttackSurface(surfaceDomain) }
                        }
                    },
                    modifier = Modifier.fillMaxWidth()
                ) { Text("Skanuj Attack Surface") }
            }

            "Firmware" -> {
                OutlinedTextField(
                    value = firmwarePath,
                    onValueChange = { firmwarePath = it },
                    label = { Text("Ścieżka pliku binarnego/firmware") },
                    modifier = Modifier.fillMaxWidth()
                )
                Button(
                    onClick = {
                        scope.launch {
                            outputText = withContext(Dispatchers.IO) {
                                val f = File(firmwarePath.trim())
                                if (!f.exists() || !f.isFile) "BŁĄD: Nie znaleziono pliku ${firmwarePath.trim()}"
                                else AuditEngine.scanFirmwareBytes(f.readBytes(), f.name)
                            }
                        }
                    },
                    modifier = Modifier.fillMaxWidth()
                ) { Text("Analizuj binarny plik") }
            }

            "Keystroke" -> {
                OutlinedTextField(
                    value = vbsLine,
                    onValueChange = { vbsLine = it },
                    label = { Text("TYPE blok (linia tekstu)") },
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = vbsDelay,
                    onValueChange = { vbsDelay = it },
                    label = { Text("DELAY blok (ms)") },
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = vbsKey,
                    onValueChange = { vbsKey = it },
                    label = { Text("Klucz specjalny (ENTER, TAB, WIN+R, CTRL+C)") },
                    modifier = Modifier.fillMaxWidth()
                )
                Button(
                    onClick = {
                        scope.launch {
                            outputText = withContext(Dispatchers.IO) {
                                val delayVal = vbsDelay.trim().toIntOrNull() ?: 500
                                val script = AuditEngine.buildKeystrokeVbs(vbsLine, delayVal, vbsKey)
                                val outFile = File("/sdcard/OceanAuditSuite/keystroke_forge_lab_only.vbs")
                                outFile.parentFile?.mkdirs()
                                outFile.writeText(script)
                                "Zapisano ${outFile.absolutePath}\n\n$script"
                            }
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFD32F2F)),
                    modifier = Modifier.fillMaxWidth()
                ) { Text("FORGE.VBS", color = Color.White) }
            }

            "PMKID" -> {
                OutlinedTextField(
                    value = pmkidLine,
                    onValueChange = { pmkidLine = it },
                    label = { Text("Linia 22000 (WPA*01*...)") },
                    modifier = Modifier.fillMaxWidth()
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = pmkidOwned, onCheckedChange = { pmkidOwned = it })
                    Text("I own this network", color = Color.White)
                }
                Button(
                    onClick = {
                        scope.launch {
                            outputText = withContext(Dispatchers.Default) {
                                AuditEngine.crackPmkid22000(pmkidLine, pmkidOwned, candidatesInput)
                            }
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFD32F2F)),
                    modifier = Modifier.fillMaxWidth()
                ) { Text("SNATCH", color = Color.White) }
            }
        }

        Button(
            onClick = {
                val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("OceanAuditSuite", outputText))
            },
            modifier = Modifier.fillMaxWidth()
        ) { Text("Kopiuj wynik do schowka") }

        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = outputText,
            color = Color(0xFFE0F2F1),
            fontFamily = FontFamily.Monospace,
            modifier = Modifier.fillMaxWidth()
        )
    }
}
MAINEOF

cd "$PROJECT_DIR"
if [ -x "${PROJECT_DIR}/gradlew" ]; then
  "${PROJECT_DIR}/gradlew" assembleDebug --rerun-tasks --offline || "${PROJECT_DIR}/gradlew" assembleDebug --rerun-tasks
else
  gradle assembleDebug --rerun-tasks --offline || gradle assembleDebug --rerun-tasks
fi

BUILT_APK="${PROJECT_DIR}/app/build/outputs/apk/debug/app-debug.apk"
[ -f "$BUILT_APK" ] || BUILT_APK="$(find "${PROJECT_DIR}/app/build/outputs/apk" -name '*.apk' -type f | head -n 1)"
[ -f "$BUILT_APK" ] || { echo "BŁĄD: Brak zbudowanego APK" >&2; exit 1; }

cp -f "$BUILT_APK" "$DIST_APK"
cp -f "$DIST_APK" "$INTERNAL_APK"
cp -f "$DIST_APK" "$DOWNLOAD_APK"

NEW_SHA="$(sha256sum "$DIST_APK" | awk '{print $1}')"
for copy in "$DIST_APK" "$DOWNLOAD_APK" "$INTERNAL_APK"; do
  [ "$(sha256sum "$copy" | awk '{print $1}')" = "$NEW_SHA" ] || { echo "BŁĄD: Niezgodny SHA-256 w $copy" >&2; exit 1; }
done

python3 - "$PROJECT_DIR" "$NEW_SHA" << 'PYEOF'
import sys
from pathlib import Path

proj = Path(sys.argv[1])
sha = sys.argv[2]
for f in proj.glob("*.sh"):
    if f.name == "build_full_7_tools_suite.sh":
        continue
    lines = [
        f'EXPECTED_SHA="${{EXPECTED_SHA:-{sha}}}"\n' if ln.startswith("EXPECTED_SHA=") else ln
        for ln in f.read_text(encoding="utf-8").splitlines(keepends=True)
    ]
    f.write_text("".join(lines), encoding="utf-8")
PYEOF

DAEMON_PID="none"
if [ -f "$DAEMON_PID_FILE" ]; then
  dpid="$(tr -d '[:space:]' < "$DAEMON_PID_FILE")"
  if [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null; then
    DAEMON_PID="$dpid"
  fi
fi

ADB_STATE="offline"
APP_PID="none"
if command -v adb >/dev/null 2>&1; then
  adb connect "${ADB_TARGET:-$DEFAULT_ADB_TARGET}" >/dev/null 2>&1 || true
  if adb get-state >/dev/null 2>&1; then
    ADB_STATE="device"
    adb shell am force-stop "$PKG_NAME" >/dev/null 2>&1 || true
    adb uninstall "$PKG_NAME" >/dev/null 2>&1 || true
    adb install -r -t -d "$INTERNAL_APK" >/dev/null 2>&1 || true
    adb shell am start -n "$ACTIVITY_NAME" >/dev/null 2>&1 || true
    sleep 1
    APP_PID="$(adb shell pidof "$PKG_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
    [ -n "$APP_PID" ] || APP_PID="none"
  fi
fi

git add -A
if ! git diff --cached --quiet; then
  git commit -m "Implement full 7-tool Ocean Audit Suite, build APK, and sync"
  TOKEN="$(resolve_gh_token)"
  if [ -n "$TOKEN" ]; then
    git push "https://${GH_OWNER}:${TOKEN}@github.com/${GH_OWNER}/${GH_REPO}.git" main || true
  elif [ -n "${GH_TOKEN:-}" ]; then
    git push origin main || true
  fi
fi

HEAD_SHA="$(git rev-parse --short HEAD)"
TS="$(date '+%Y-%m-%d %H:%M:%S')"

{
  printf 'TIMESTAMP=%s\n' "$TS"
  printf 'PACKAGE=%s\n' "$PKG_NAME"
  printf 'SHA256=%s\n' "$NEW_SHA"
  printf 'DIST_APK=%s\n' "$DIST_APK"
  printf 'DOWNLOAD_APK=%s\n' "$DOWNLOAD_APK"
  printf 'INTERNAL_APK=%s\n' "$INTERNAL_APK"
  printf 'DAEMON_PID=%s\n' "$DAEMON_PID"
  printf 'ADB_STATE=%s\n' "$ADB_STATE"
  printf 'APP_PID=%s\n' "$APP_PID"
  printf 'GIT_HEAD=%s\n' "$HEAD_SHA"
} > "$STATUS_FILE"

{
  printf '=== FULL 7-TOOLS SUITE RELEASE (%s) ===\n' "$TS"
  printf 'PACKAGE=%s\n' "$PKG_NAME"
  printf 'SHA256=%s\n' "$NEW_SHA"
  printf 'ADB_STATE=%s\n' "$ADB_STATE"
  printf 'DAEMON_PID=%s\n' "$DAEMON_PID"
  printf 'APP_PID=%s\n' "$APP_PID"
  printf 'GIT_HEAD=%s\n' "$HEAD_SHA"
  ls -lh "$DIST_APK" "$DOWNLOAD_APK" "$INTERNAL_APK"
} > "$RELEASE_LOG"

echo "FULL_7_SUITE_OK: pkg=${PKG_NAME} adb=${ADB_STATE} app_pid=${APP_PID} head=${HEAD_SHA} sha256=${NEW_SHA}"
