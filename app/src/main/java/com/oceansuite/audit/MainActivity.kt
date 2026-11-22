package com.oceansuite.audit

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    OceanAuditScreen()
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun OceanAuditScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val tabs = listOf("Bucket", "Doppelganger", "Hash", "Surface", "Firmware", "Keystroke", "PMKID")
    var selectedTab by remember { mutableStateOf(0) }

    var brandInput by remember { mutableStateOf("") }
    var bucketOwned by remember { mutableStateOf(false) }

    var domainInput by remember { mutableStateOf("") }

    var hashInput by remember { mutableStateOf("") }
    var candidatesInput by remember { mutableStateOf("") }
    var hashOwned by remember { mutableStateOf(false) }

    var surfaceDomain by remember { mutableStateOf("") }

    var firmwarePath by remember { mutableStateOf("/sdcard/OceanAuditSuite/OceanAuditSuite.apk") }

    var vbsText by remember { mutableStateOf("echo LAB_ONLY") }
    var vbsDelay by remember { mutableStateOf("500") }
    var vbsKey by remember { mutableStateOf("ENTER") }

    var pmkidLine by remember { mutableStateOf("") }
    var pmkidOwned by remember { mutableStateOf(false) }

    var output by remember { mutableStateOf("Gotowe. Wybierz modul i podaj wlasne dane wejsciowe.") }
    var busy by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(12.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Text("OCEAN AUDIT SUITE v2.0", style = MaterialTheme.typography.titleLarge)

        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            tabs.forEachIndexed { idx, label ->
                FilterChip(
                    selected = selectedTab == idx,
                    onClick = { selectedTab = idx },
                    label = { Text(label) }
                )
            }
        }

        when (selectedTab) {
            0 -> {
                OutlinedTextField(
                    value = brandInput,
                    onValueChange = { brandInput = it },
                    label = { Text("Wlasna marka lub bucket (np. moj-bucket)") },
                    modifier = Modifier.fillMaxWidth()
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = bucketOwned, onCheckedChange = { bucketOwned = it })
                    Text("I own this bucket / brand")
                }
                Button(
                    enabled = !busy,
                    onClick = {
                        busy = true
                        scope.launch {
                            output = withContext(Dispatchers.IO) {
                                AuditEngine.runBucketBuster(brandInput, bucketOwned)
                            }
                            busy = false
                        }
                    }
                ) { Text(if (busy) "SKANOWANIE..." else "RAID") }
            }

            1 -> {
                OutlinedTextField(
                    value = domainInput,
                    onValueChange = { domainInput = it },
                    label = { Text("Wlasna domena (np. przyklad.pl)") },
                    modifier = Modifier.fillMaxWidth()
                )
                Button(
                    enabled = !busy,
                    onClick = {
                        busy = true
                        scope.launch {
                            output = withContext(Dispatchers.IO) {
                                AuditEngine.runDoppelganger(domainInput)
                            }
                            busy = false
                        }
                    }
                ) { Text(if (busy) "RADAR..." else "Skanuj radar domen") }
            }

            2 -> {
                Text("Wykryty typ: ${AuditEngine.detectHashAlgo(hashInput)}")
                OutlinedTextField(
                    value = hashInput,
                    onValueChange = { hashInput = it },
                    label = { Text("Skrot HEX (32 MD5 / 40 SHA1 / 64 SHA256)") },
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = candidatesInput,
                    onValueChange = { candidatesInput = it },
                    label = { Text("Kandydaci hasel (oddzielone przecinkiem lub nowa linia)") },
                    modifier = Modifier.fillMaxWidth()
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = hashOwned, onCheckedChange = { hashOwned = it })
                    Text("I own this hash")
                }
                Button(
                    enabled = !busy,
                    onClick = {
                        busy = true
                        scope.launch {
                            output = withContext(Dispatchers.IO) {
                                AuditEngine.crackHash(hashInput, candidatesInput, hashOwned)
                            }
                            busy = false
                        }
                    }
                ) { Text(if (busy) "OBLICZANIE..." else "CRACK") }
            }

            3 -> {
                OutlinedTextField(
                    value = surfaceDomain,
                    onValueChange = { surfaceDomain = it },
                    label = { Text("Wlasna domena (Panels / Logs / Keys)") },
                    modifier = Modifier.fillMaxWidth()
                )
                Button(
                    enabled = !busy,
                    onClick = {
                        busy = true
                        scope.launch {
                            output = withContext(Dispatchers.IO) {
                                AuditEngine.runAttackSurface(surfaceDomain)
                            }
                            busy = false
                        }
                    }
                ) { Text(if (busy) "SKANOWANIE..." else "Skanuj Attack Surface") }
            }

            4 -> {
                OutlinedTextField(
                    value = firmwarePath,
                    onValueChange = { firmwarePath = it },
                    label = { Text("Sciezka pliku binarnego / firmware / APK") },
                    modifier = Modifier.fillMaxWidth()
                )
                Button(
                    enabled = !busy,
                    onClick = {
                        busy = true
                        scope.launch {
                            output = withContext(Dispatchers.IO) {
                                val f = File(firmwarePath.trim())
                                if (!f.exists() || !f.canRead()) {
                                    "BLAD: Plik nie istnieje lub brak uprawnien do odczytu: ${f.absolutePath}"
                                } else {
                                    AuditEngine.scanFirmwareBytes(f.readBytes(), f.name)
                                }
                            }
                            busy = false
                        }
                    }
                ) { Text(if (busy) "ANALIZA..." else "Analizuj binarny plik") }
            }

            5 -> {
                OutlinedTextField(
                    value = vbsText,
                    onValueChange = { vbsText = it },
                    label = { Text("TYPE blok (linia tekstu)") },
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = vbsDelay,
                    onValueChange = { vbsDelay = it },
                    label = { Text("DELAY blok (ms, 50..60000)") },
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = vbsKey,
                    onValueChange = { vbsKey = it },
                    label = { Text("Klucz specjalny (ENTER, TAB, WIN+R, CTRL+C, CTRL+V, CTRL+A)") },
                    modifier = Modifier.fillMaxWidth()
                )
                Button(
                    enabled = !busy,
                    onClick = {
                        busy = true
                        scope.launch {
                            output = withContext(Dispatchers.IO) {
                                val delayVal = vbsDelay.trim().toIntOrNull() ?: 500
                                val script = AuditEngine.buildKeystrokeVbs(vbsText, delayVal, vbsKey)
                                val outDir = File("/sdcard/OceanAuditSuite")
                                if (!outDir.exists()) outDir.mkdirs()
                                val outFile = File(outDir, "keystroke_forge_lab_only.vbs")
                                outFile.writeText(script, Charsets.UTF_8)
                                "Zapisano do: ${outFile.absolutePath}\n\n$script"
                            }
                            busy = false
                        }
                    }
                ) { Text(if (busy) "GENEROWANIE..." else "FORGE.VBS") }
            }

            6 -> {
                OutlinedTextField(
                    value = pmkidLine,
                    onValueChange = { pmkidLine = it },
                    label = { Text("Linia 22000 (WPA*01*<pmkid>*<ap>*<sta>*<essid>***)") },
                    modifier = Modifier.fillMaxWidth()
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = pmkidOwned, onCheckedChange = { pmkidOwned = it })
                    Text("I own this network")
                }
                Button(
                    enabled = !busy,
                    onClick = {
                        busy = true
                        scope.launch {
                            output = withContext(Dispatchers.IO) {
                                AuditEngine.crackPmkid22000(pmkidLine, pmkidOwned, candidatesInput)
                            }
                            busy = false
                        }
                    }
                ) { Text(if (busy) "WERYFIKACJA..." else "SNATCH") }
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = {
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("OceanAuditOutput", output))
            }) { Text("Kopiuj wynik do schowka") }
            OutlinedButton(onClick = {
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
                output = "Zapisano raport: ${reportFile.absolutePath}\n\n$output"
            }) { Text("Zapisz raport .txt") }
        }

        OutlinedTextField(
            value = output,
            onValueChange = { output = it },
            label = { Text("Raport / Wynik") },
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 220.dp),
            textStyle = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)
        )
    }
}
