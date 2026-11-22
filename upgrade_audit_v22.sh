#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/audit_apk_project"
PKG_PATH="${PROJECT_DIR}/app/src/main/java/com/oceansuite/audit"
ENGINE_FILE="${PKG_PATH}/AuditEngine.kt"
MAIN_FILE="${PKG_PATH}/MainActivity.kt"
RELEASE_SCRIPT="${PROJECT_DIR}/build_and_release_v2.sh"

[ -f "$ENGINE_FILE" ] || { echo "BLAD: Brak pliku $ENGINE_FILE" >&2; exit 1; }
[ -f "$MAIN_FILE" ] || { echo "BLAD: Brak pliku $MAIN_FILE" >&2; exit 1; }

python3 - "$ENGINE_FILE" << 'PYEOF'
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])
src = p.read_text(encoding="utf-8")

start_marker = "    fun runDoppelganger(domainInput: String): String {"
end_marker = "    fun scanFirmwareBytes(bytes: ByteArray, label: String): String {"

s_idx = src.find(start_marker)
e_idx = src.find(end_marker)
if s_idx == -1 or e_idx == -1:
    raise RuntimeError("Nie znaleziono granic funkcji w AuditEngine.kt")

replacement = '''    fun runDoppelganger(domainInput: String): String {
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
        val hasCaa = caaResp.contains("\\"data\\"")

        val sb = StringBuilder()
        sb.append("=== DOPPELGANGER & DNS POSTURE RADAR ===\\n")
        sb.append("Domena bazowa: $cleanRoot\\n")
        sb.append("Polityka DNS: SPF=${if (hasSpf) "OK" else "BRAK"} | DMARC=${if (hasDmarc) "OK" else "BRAK"} | CAA=${if (hasCaa) "OK" else "BRAK"}\\n")
        var regCount = 0
        var mxCount = 0
        for (cand in candidates) {
            val aJson = httpGet("https://dns.google/resolve?name=$cand&type=A")?.body ?: ""
            val mxJson = httpGet("https://dns.google/resolve?name=$cand&type=MX")?.body ?: ""
            val hasA = aJson.contains("\\"data\\"")
            val hasMx = mxJson.contains("\\"data\\"")
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
            sb.append("$cand -> $status\\n")
        }
        sb.append("Podsumowanie: zarejestrowane=$regCount, z MX=$mxCount, sprawdzone=${candidates.size}\\n")
        sb.append("Obrona: Utrzymuj rekordy SPF/DMARC/CAA, monitoruj podobne domeny i rejestruj krytyczne warianty.\\n")
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
        val customWords = candidatesRaw.split(Regex("[\\\\r\\\\n,]+")).map { it.trim() }.filter { it.isNotEmpty() }
        val pool = (customWords + COMMON_WORDS).distinct()
        val startNs = System.nanoTime()
        var attempts = 0
        for (word in pool) {
            attempts++
            if (digestHex(algo, word) == target) {
                val elapsedMs = (System.nanoTime() - startNs) / 1_000_000.0
                return "=== HASH CRACKER REPORT ===\\nAlgorytm: $algo\\nCel: $target\\nStatus: CRACKED: $word\\nLiczba prob: $attempts\\nCzas: ${String.format(Locale.US, "%.3f", elapsedMs)} ms\\nObrona: Stosuj wolne haszowanie z sola (Argon2id / bcrypt) oraz dlugie unikalne hasla."
            }
        }
        val elapsedMs = (System.nanoTime() - startNs) / 1_000_000.0
        return "=== HASH CRACKER REPORT ===\\nAlgorytm: $algo\\nCel: $target\\nStatus: NOT FOUND\\nLiczba prob: $attempts\\nCzas: ${String.format(Locale.US, "%.3f", elapsedMs)} ms\\nObrona: Stosuj wolne haszowanie z sola (Argon2id / bcrypt) oraz dlugie unikalne hasla."
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
                val emails = Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\\\.[A-Za-z]{2,}").findAll(r.body).count()
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
            append("=== ATTACK SURFACE & HEADER AUDIT ===\\n")
            append("Cel: $cleanDomain | EXPOSURE: $severity | Loot: $totalLoot | Brakujace naglowki: $missingCount\\n")
            append("[Naglowki HTTP] $secHeaders\\n")
            append("[Karta 1: Panels (${openPanels.size}/${PANEL_PATHS.size})] ${if (openPanels.isEmpty()) "Brak otwartych paneli" else openPanels.joinToString("; ")}\\n")
            append("  Obrona: Uwierzytelnianie, ograniczenie IP i usuwanie nieuzywanych endpointow.\\n")
            append("[Karta 2: Logs (${logHits.size})] ${if (logHits.isEmpty()) "Brak wyciekow w logach" else logHits.joinToString("; ")}\\n")
            append("  Obrona: Nie udostepniaj logow w katalogu web, rotuj logi i maskuj sekrety.\\n")
            append("[Karta 3: Keys (${keyHits.size})] ${if (keyHits.isEmpty()) "Brak kluczy prywatnych" else keyHits.joinToString("; ")}\\n")
            append("  Obrona: Trzymaj klucze poza web root, stosuj chmod 600 i rotuj klucze przy ekspozycji.\\n")
        }
    }

'''

updated = src[:s_idx] + replacement + src[e_idx:]

new_http = '''    private data class HttpResult(val code: Int, val body: String, val secHeaders: String)

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
    }'''

pattern = re.compile(
    r"    private data class HttpResult\(.*?^    \}",
    re.DOTALL | re.MULTILINE
)
if not pattern.search(updated):
    raise RuntimeError("Nie znaleziono bloku HttpResult/httpGet w AuditEngine.kt")

updated = pattern.sub(new_http, updated, count=1)
p.write_text(updated, encoding="utf-8")
PYEOF

python3 - "$MAIN_FILE" << 'PYEOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
src = p.read_text(encoding="utf-8")

export_block = '''            OutlinedButton(onClick = {
                val outDir = File("/sdcard/OceanAuditSuite")
                if (!outDir.exists()) outDir.mkdirs()
                val safeTarget = when (selectedTab) {
                    0 -> brandInput.trim().replace(Regex("[^a-zA-Z0-9._-]"), "_")
                    1 -> domainInput.trim().replace(Regex("[^a-zA-Z0-9._-]"), "_")
                    3 -> surfaceDomain.trim().replace(Regex("[^a-zA-Z0-9._-]"), "_")
                    else -> "module_${selectedTab}"
                }.ifEmpty { "audit" }
                val reportFile = File(outDir, "audit_report_${safeTarget}.txt")
                reportFile.writeText(output, Charsets.UTF_8)
                output = "Zapisano raport: ${reportFile.absolutePath}\\n\\n$output"
            }) { Text("Zapisz raport .txt") }'''

anchor = '''            OutlinedButton(onClick = {
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("OceanAuditOutput", output))
            }) { Text("Kopiuj wynik do schowka") }'''

if anchor not in src:
    raise RuntimeError("Nie znaleziono przycisku kopiowania w MainActivity.kt")

if "Zapisz raport .txt" not in src:
    src = src.replace(anchor, anchor + "\n" + export_block, 1)
    p.write_text(src, encoding="utf-8")
PYEOF

if [ -x "$RELEASE_SCRIPT" ]; then
  "$RELEASE_SCRIPT"
fi
