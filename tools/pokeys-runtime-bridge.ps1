param(
    [int]$PollMs = 20,
    [int]$AuxByteIndex = 9,
    [int]$OutBase = 1,
    [int]$StrobeOut = 9
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$dllPath = Join-Path $scriptDir 'PoKeys.dll'
if (-not (Test-Path $dllPath)) {
    throw "PoKeys.dll not found: $dllPath"
}

Add-Type -Path $dllPath
$device = New-Object PoKeysDevice_DLL.PoKeysDevice

$count = $device.EnumerateDevices()
if ($count -lt 1) {
    throw 'No PoKeys device detected.'
}

if (-not $device.ConnectToDevice(0)) {
    throw 'Failed to connect to first detected PoKeys device.'
}

Write-Output 'PoKeys runtime bridge connected. Press Ctrl+C to stop.'

$lastValue = -1

try {
    while ($true) {
        $enabled = [byte]0
        $data = New-Object 'System.Byte[]' 10

        $okEnabled = $device.AuxilaryBusGetData([ref]$enabled)
        $okData = $device.AuxilaryBusGetData([ref]$data)

        if ($okEnabled -and $okData -and $enabled -eq 1) {
            $value = [int]$data[$AuxByteIndex]

            if ($value -ne $lastValue) {
                $lastValue = $value

                $outs = New-Object 'System.Boolean[]' 55
                for ($b = 0; $b -lt 8; $b++) {
                    $pinIndex = ($OutBase - 1) + $b
                    if ($pinIndex -ge 0 -and $pinIndex -lt 55) {
                        $outs[$pinIndex] = ((($value -shr $b) -band 1) -eq 1)
                    }
                }

                $strobeIndex = $StrobeOut - 1
                if ($strobeIndex -ge 0 -and $strobeIndex -lt 55) {
                    $outs[$strobeIndex] = $true
                }

                [void]$device.BlockSetOutputAll55([ref]$outs)
                Start-Sleep -Milliseconds 1

                if ($strobeIndex -ge 0 -and $strobeIndex -lt 55) {
                    $outs[$strobeIndex] = $false
                }

                [void]$device.BlockSetOutputAll55([ref]$outs)
            }
        }

        Start-Sleep -Milliseconds $PollMs
    }
}
finally {
    $device.DisconnectDevice()
}
