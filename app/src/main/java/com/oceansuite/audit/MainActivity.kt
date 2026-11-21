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
