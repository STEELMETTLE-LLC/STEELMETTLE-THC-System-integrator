param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = 'Stop'

# --- constants ---
$OUT_BASE   = 1    # PoKeys pin # for PoExt D0 (1-based)
$STROBE_OUT = 9    # PoKeys pin # for PoExt STROBE (1-based)
$PIN_FUNC_DIGITAL_OUTPUT = 0x04   # bit 2 = digital output
$PIN_FUNC_DIGITAL_INPUT  = 0x02   # bit 1 = digital input

# --- THC signal pin mapping (1-based PoKeys pin numbers) ---
# Outputs: PoKeys encoder connector → Arduino inputs (DIO33, 3.3V)
$THC_ENABLE_PIN   = 12   # Encoder pin 5 (PK12) → Arduino D25
$THC_ALLOWED_PIN  = 13   # Encoder pin 7 (PK13) → Arduino D26
$FEEDRATE_OK_PIN  = 20   # Encoder pin 9 (PK20) → Arduino D27

# Inputs: Arduino outputs → PoKeys pendant connector (DI33P, 3.3V, needs 5V divider)
$THC_UP_PIN       = 10   # Pendant pin 15 (PK10) ← Arduino D23
$THC_DOWN_PIN     = 11   # Pendant pin 17 (PK11) ← Arduino D24
$TORCH_ON_PIN     = 15   # Pendant pin 23 (PK15) ← Arduino D29
$ARC_OK_OUT_PIN   = 16   # Pendant pin 25 (PK16) ← Arduino D28

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$dllPath   = Join-Path $scriptDir 'PoKeys.dll'
$bridgeScript = Join-Path $scriptDir 'pokeys-runtime-bridge.ps1'

function Get-PinFunctionByte([object]$Device, [int]$PinNumber) {
    $pinFunc = [byte]0
    try {
        [void]$Device.GetPinData([byte]($PinNumber - 1), [ref]$pinFunc)
    } catch {
    }
    return $pinFunc
}

function Test-RequiredPinAssignments([object]$Device) {
    $failures = New-Object System.Collections.Generic.List[string]

    foreach ($entry in @(
        @{ Pin = $THC_ENABLE_PIN;  Name = 'THC_ENABLE';  Mask = $PIN_FUNC_DIGITAL_OUTPUT; Expected = 'digital output' },
        @{ Pin = $THC_ALLOWED_PIN; Name = 'THC_ALLOWED'; Mask = $PIN_FUNC_DIGITAL_OUTPUT; Expected = 'digital output' },
        @{ Pin = $FEEDRATE_OK_PIN; Name = 'FEEDRATE_OK'; Mask = $PIN_FUNC_DIGITAL_OUTPUT; Expected = 'digital output' },
        @{ Pin = $THC_UP_PIN;      Name = 'THC_UP';      Mask = $PIN_FUNC_DIGITAL_INPUT;  Expected = 'digital input' },
        @{ Pin = $THC_DOWN_PIN;    Name = 'THC_DOWN';    Mask = $PIN_FUNC_DIGITAL_INPUT;  Expected = 'digital input' },
        @{ Pin = $TORCH_ON_PIN;    Name = 'TORCH_ON';    Mask = $PIN_FUNC_DIGITAL_INPUT;  Expected = 'digital input' },
        @{ Pin = $ARC_OK_OUT_PIN;  Name = 'ARC_OK_OUT';  Mask = $PIN_FUNC_DIGITAL_INPUT;  Expected = 'digital input' }
    )) {
        $pinFunc = Get-PinFunctionByte -Device $Device -PinNumber $entry.Pin
        if (($pinFunc -band $entry.Mask) -eq 0) {
            $failures.Add("$($entry.Name) on pin $($entry.Pin) is not configured as $($entry.Expected)")
        }
    }

    return @($failures)
}

# --- parse arguments ---
$doDeploy  = $Args -contains '--deploy'
$runBridge = $Args -contains '--run-bridge'
$doVerify  = $Args -contains '--verify'

if (-not $doDeploy -and -not $runBridge -and -not $doVerify) {
    Write-Error 'Usage: pokeys-cli.ps1 --deploy | --run-bridge | --verify'
    exit 2
}

# --- load DLL ---
if (-not (Test-Path $dllPath)) {
    Write-Error "PoKeys.dll not found: $dllPath"
    exit 3
}
Add-Type -Path $dllPath

# --- connect to device ---
$device = New-Object PoKeysDevice_DLL.PoKeysDevice
$count = $device.EnumerateDevices()
if ($count -lt 1) {
    Write-Error 'No PoKeys device detected. Connect your PoKeys57CNC via USB and try again.'
    exit 4
}
if (-not $device.ConnectToDevice(0)) {
    Write-Error 'Failed to connect to PoKeys device.'
    exit 4
}
Write-Output "Connected to PoKeys device (serial: $($device.DeviceData.SerialNumber))"

# --- verify command ---
if ($doVerify) {
    # Check PoExtBus pin status
    Write-Output 'PoExtBus pins (1-9):'
    for ($pin = $OUT_BASE; $pin -le $STROBE_OUT; $pin++) {
        $pinFunc = [byte]0
        try {
            [void]$device.GetPinData([byte]($pin - 1), [ref]$pinFunc)
        } catch {}
        $isOutput = ($pinFunc -band $PIN_FUNC_DIGITAL_OUTPUT) -ne 0
        $status = if ($isOutput) { 'digital output' } else { 'other function' }
        Write-Output "  Pin $pin : $status"
    }

    # Check THC signal output pins (PoKeys → Arduino)
    Write-Output 'THC output pins (PoKeys encoder connector -> Arduino):'
    foreach ($entry in @(
        @{ Pin = $THC_ENABLE_PIN;  Name = 'THC_ENABLE  (PK{0} -> Arduino D25)' -f $THC_ENABLE_PIN },
        @{ Pin = $THC_ALLOWED_PIN; Name = 'THC_ALLOWED (PK{0} -> Arduino D26)' -f $THC_ALLOWED_PIN },
        @{ Pin = $FEEDRATE_OK_PIN; Name = 'FEEDRATE_OK (PK{0} -> Arduino D27)' -f $FEEDRATE_OK_PIN }
    )) {
        $pinFunc = [byte]0
        try { [void]$device.GetPinData([byte]($entry.Pin - 1), [ref]$pinFunc) } catch {}
        $isOutput = ($pinFunc -band $PIN_FUNC_DIGITAL_OUTPUT) -ne 0
        $mark = if ($isOutput) { 'OK' } else { 'NOT CONFIGURED' }
        Write-Output "  $($entry.Name) : $mark"
    }

    # Check THC signal input pins (Arduino → PoKeys)
    Write-Output 'THC input pins (Arduino -> PoKeys pendant connector):'
    foreach ($entry in @(
        @{ Pin = $THC_UP_PIN;     Name = 'THC_UP      (PK{0} <- Arduino D23)' -f $THC_UP_PIN },
        @{ Pin = $THC_DOWN_PIN;   Name = 'THC_DOWN    (PK{0} <- Arduino D24)' -f $THC_DOWN_PIN },
        @{ Pin = $TORCH_ON_PIN;   Name = 'TORCH_ON    (PK{0} <- Arduino D29)' -f $TORCH_ON_PIN },
        @{ Pin = $ARC_OK_OUT_PIN; Name = 'ARC_OK_OUT  (PK{0} <- Arduino D28)' -f $ARC_OK_OUT_PIN }
    )) {
        $pinFunc = [byte]0
        try { [void]$device.GetPinData([byte]($entry.Pin - 1), [ref]$pinFunc) } catch {}
        $isInput = ($pinFunc -band $PIN_FUNC_DIGITAL_INPUT) -ne 0
        $mark = if ($isInput) { 'OK' } else { 'NOT CONFIGURED' }
        Write-Output "  $($entry.Name) : $mark"
    }

    # Try to read PoExtBus and write a test byte
    Write-Output '  Testing PoExtBus write...'
    $testData = New-Object 'System.Byte[]' 10
    $testData[9] = 0xAA
    $writeOk = $device.AuxilaryBusSetData([byte]1, $testData)
    # Clear it back
    $clearData = New-Object 'System.Byte[]' 10
    [void]$device.AuxilaryBusSetData([byte]1, $clearData)

    $pinFailures = @(Test-RequiredPinAssignments -Device $device)

    $device.DisconnectDevice()
    if (-not $writeOk) {
        Write-Error 'Verification FAILED: PoExtBus write returned false.'
        exit 5
    }
    if ($pinFailures.Count -gt 0) {
        $pinFailures | ForEach-Object { Write-Error "Verification FAILED: $_" }
        exit 6
    }

    if ($writeOk) {
        Write-Output 'Verification PASSED: PoExtBus is responding.'
        exit 0
    }
}

# --- deploy command ---
if ($doDeploy) {
    # Step 1: Enable PoExtBus (AuxilaryBus) - this is the critical step
    Write-Output 'Enabling PoExtBus (AuxilaryBus)...'
    $dataOut = New-Object 'System.Byte[]' 10
    $ok = $device.AuxilaryBusSetData([byte]1, $dataOut)
    if (-not $ok) {
        $device.DisconnectDevice()
        Write-Error 'Failed to enable PoExtBus.'
        exit 7
    }
    Write-Output '  PoExtBus enabled.'

    # Step 2: Try to configure pins 1-9 as digital outputs (best-effort)
    # Some pins on PoKeys57CNC may be reserved for CNC functions and cannot
    # be reassigned. This is normal - the PoExtBus hardware path does not
    # require GPIO pin configuration.
    Write-Output 'Configuring PoKeys pins 1-9 as digital outputs (best-effort)...'
    $pinOkCount = 0
    $pinFailCount = 0
    for ($pin = $OUT_BASE; $pin -le $STROBE_OUT; $pin++) {
        $ok = $device.SetPinData([byte]($pin - 1), [byte]$PIN_FUNC_DIGITAL_OUTPUT)
        if ($ok) {
            Write-Output "  Pin $pin -> digital output"
            $pinOkCount++
        } else {
            Write-Output "  Pin $pin -> SKIPPED (reserved for CNC function)"
            $pinFailCount++
        }
    }
    if ($pinFailCount -gt 0) {
        Write-Output "  $pinOkCount pins configured, $pinFailCount pins skipped (CNC-reserved)."
        Write-Output '  NOTE: PoExtBus hardware path does not require GPIO pins.'
    }

    # Step 3: Configure THC signal output pins (PoKeys → Arduino via encoder connector)
    Write-Output 'Configuring THC output pins (encoder connector -> Arduino)...'
    foreach ($entry in @(
        @{ Pin = $THC_ENABLE_PIN;  Name = 'THC_ENABLE  (PK{0})' -f $THC_ENABLE_PIN },
        @{ Pin = $THC_ALLOWED_PIN; Name = 'THC_ALLOWED (PK{0})' -f $THC_ALLOWED_PIN },
        @{ Pin = $FEEDRATE_OK_PIN; Name = 'FEEDRATE_OK (PK{0})' -f $FEEDRATE_OK_PIN }
    )) {
        $ok = $device.SetPinData([byte]($entry.Pin - 1), [byte]$PIN_FUNC_DIGITAL_OUTPUT)
        if ($ok) {
            Write-Output "  $($entry.Name) -> digital output"
        } else {
            Write-Output "  $($entry.Name) -> FAILED (pin may be reserved)"
        }
    }

    # Step 4: Configure THC signal input pins (Arduino → PoKeys via pendant connector)
    Write-Output 'Configuring THC input pins (Arduino -> pendant connector)...'
    foreach ($entry in @(
        @{ Pin = $THC_UP_PIN;     Name = 'THC_UP      (PK{0})' -f $THC_UP_PIN },
        @{ Pin = $THC_DOWN_PIN;   Name = 'THC_DOWN    (PK{0})' -f $THC_DOWN_PIN },
        @{ Pin = $TORCH_ON_PIN;   Name = 'TORCH_ON    (PK{0})' -f $TORCH_ON_PIN },
        @{ Pin = $ARC_OK_OUT_PIN; Name = 'ARC_OK_OUT  (PK{0})' -f $ARC_OK_OUT_PIN }
    )) {
        $ok = $device.SetPinData([byte]($entry.Pin - 1), [byte]$PIN_FUNC_DIGITAL_INPUT)
        if ($ok) {
            Write-Output "  $($entry.Name) -> digital input"
        } else {
            Write-Output "  $($entry.Name) -> FAILED (pin may be reserved)"
        }
    }

    # Step 5: Save configuration to device flash
    Write-Output 'Saving configuration to device flash...'
    $ok = $device.SaveConfiguration()
    if (-not $ok) {
        $device.DisconnectDevice()
        Write-Error 'Failed to save configuration to device.'
        exit 8
    }
    Write-Output 'Device configuration saved successfully.'

    $pinFailures = @(Test-RequiredPinAssignments -Device $device)
    if ($pinFailures.Count -gt 0) {
        $device.DisconnectDevice()
        $pinFailures | ForEach-Object { Write-Error "Post-deploy verification FAILED: $_" }
        exit 9
    }

    Write-Output 'Post-deploy verification PASSED: required THC pins match the expected directions.'

    $device.DisconnectDevice()

    # Start the runtime bridge
    if (Test-Path $bridgeScript) {
        Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $bridgeScript)
        ) | Out-Null
        Write-Output 'Runtime bridge started (hidden). It reads AuxBus feedrate and writes to PoExt D0-D7 + STROBE.'
    } else {
        Write-Output "WARNING: Bridge script not found at $bridgeScript - bridge not started."
    }

    Write-Output 'PoKeys deployment complete. Device is configured for THC data relay.'
    exit 0
}

# --- run-bridge only ---
if ($runBridge) {
    $device.DisconnectDevice()
    if (-not (Test-Path $bridgeScript)) {
        Write-Error "Bridge script not found: $bridgeScript"
        exit 10
    }
    Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $bridgeScript)
    ) | Out-Null
    Write-Output 'PoKeys runtime bridge started (hidden background process).'
    exit 0
}
