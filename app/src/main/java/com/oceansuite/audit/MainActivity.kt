package com.oceansuite.audit

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ClipboardManager
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

enum class ToolTab(val label: String) {
    BUCKET("Bucket"),
    DOPPELGANGER("Doppelganger"),
    HASH("Hash"),
    PMKID("PMKID")
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    AuditSuiteScreen()
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AuditSuiteScreen() {
    val scope = rememberCoroutineScope()
    val clipboard: ClipboardManager = LocalClipboardManager.current

    var selectedTab by remember { mutableStateOf(ToolTab.BUCKET) }
    var running by remember { mutableStateOf(false) }
    var outputText by remember { mutableStateOf("Gotowy do pracy. Wybierz moduł i uruchom analizę.") }

    var brandInput by remember { mutableStateOf("example-brand") }
    var wordsInput by remember { mutableStateOf("backup,assets,cdn") }

    var domainInput by remember { mutableStateOf("example.com") }

    var digestInput by remember { mutableStateOf("5f4dcc3b5aa765d61d8327deb882cf99") }
    var candidatesInput by remember { mutableStateOf("password\nadmin\n123456") }

    var pmkidInput by remember {
        mutableStateOf("WPA*01*00000000000000000000000000000000*112233445566*aabbccddeeff*74657374")
    }
    var pmkidPassInput by remember { mutableStateOf("password\n12345678") }

    Scaffold { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(
                text = "Ocean Audit Suite",
                style = MaterialTheme.typography.headlineSmall
            )

            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                ToolTab.entries.forEach { tab ->
                    FilterChip(
                        selected = selectedTab == tab,
                        onClick = { if (!running) selectedTab = tab },
                        label = { Text(tab.label) }
                    )
                }
            }

            when (selectedTab) {
                ToolTab.BUCKET -> {
                    OutlinedTextField(
                        value = brandInput,
                        onValueChange = { brandInput = it },
                        label = { Text("Nazwa marki lub domeny") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = wordsInput,
                        onValueChange = { wordsInput = it },
                        label = { Text("Słowa dodatkowe (oddzielone przecinkami)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Button(
                        enabled = !running,
                        onClick = {
                            running = true
                            scope.launch {
                                outputText = runCatching {
                                    AuditEngine.scanBuckets(brandInput, wordsInput)
                                }.getOrElse { "BŁĄD: ${it.message}" }
                                running = false
                            }
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text("Skanuj zasoby S3 / GCS")
                    }
                }

                ToolTab.DOPPELGANGER -> {
                    OutlinedTextField(
                        value = domainInput,
                        onValueChange = { domainInput = it },
                        label = { Text("Domena bazowa (np. example.com)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Button(
                        enabled = !running,
                        onClick = {
                            running = true
                            scope.launch {
                                outputText = runCatching {
                                    AuditEngine.auditDomains(domainInput, limit = 60)
                                }.getOrElse { "BŁĄD: ${it.message}" }
                                running = false
                            }
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text("Sprawdź warianty domeny (DNS A/MX)")
                    }
                }

                ToolTab.HASH -> {
                    OutlinedTextField(
                        value = digestInput,
                        onValueChange = { digestInput = it },
                        label = { Text("Skrót HEX (MD5 / SHA1 / SHA256)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = candidatesInput,
                        onValueChange = { candidatesInput = it },
                        label = { Text("Kandydaci haseł (po jednym w linii lub po przecinku)") },
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 90.dp)
                    )
                    Button(
                        enabled = !running,
                        onClick = {
                            running = true
                            outputText = runCatching {
                                AuditEngine.crackHash(digestInput, candidatesInput)
                            }.getOrElse { "BŁĄD: ${it.message}" }
                            running = false
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text("Weryfikuj skrót")
                    }
                }

                ToolTab.PMKID -> {
                    OutlinedTextField(
                        value = pmkidInput,
                        onValueChange = { pmkidInput = it },
                        label = { Text("Wpis WPA*01*PMKID*AP_MAC*CLIENT_MAC*ESSID_HEX") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = pmkidPassInput,
                        onValueChange = { pmkidPassInput = it },
                        label = { Text("Kandydaci haseł (po jednym w linii lub po przecinku)") },
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 90.dp)
                    )
                    Button(
                        enabled = !running,
                        onClick = {
                            running = true
                            scope.launch {
                                outputText = runCatching {
                                    AuditEngine.auditPmkid(pmkidInput, pmkidPassInput)
                                }.getOrElse { "BŁĄD: ${it.message}" }
                                running = false
                            }
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text("Oblicz i sprawdź PMKID")
                    }
                }
            }

            if (running) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            }

            Button(
                onClick = { clipboard.setText(AnnotatedString(outputText)) },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Kopiuj wynik do schowka")
            }

            Card(
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(
                    text = outputText,
                    fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(12.dp)
                )
            }
        }
    }
}
