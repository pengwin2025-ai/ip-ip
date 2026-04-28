Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:IsCompiled = [string]::IsNullOrWhiteSpace($PSCommandPath)
$script:AppRoot = if ($script:IsCompiled) {
    [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\')
}
else {
    Split-Path -Parent $PSCommandPath
}
$script:PresetFile = Join-Path $script:AppRoot "ip_presets.json"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Elevated {
    if (Test-IsAdmin) {
        return $true
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "修改 IP 需要管理员权限，是否重新以管理员身份启动？",
        "需要权限",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return $false
    }

    if ($script:IsCompiled) {
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        Start-Process -FilePath $exePath -Verb RunAs
    }
    else {
        $arguments = @(
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            ('"{0}"' -f $PSCommandPath)
        )
        Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs
    }
    return $false
}

function Get-ActiveAdapters {
    Get-NetAdapter |
        Where-Object { $_.Status -eq "Up" } |
        Sort-Object Name |
        Select-Object -ExpandProperty Name
}

function Get-Presets {
    if (-not (Test-Path $script:PresetFile)) {
        return @()
    }

    try {
        $raw = Get-Content -LiteralPath $script:PresetFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @()
        }

        $data = $raw | ConvertFrom-Json
        if ($data -is [System.Array]) {
            return @($data)
        }

        return @($data)
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "读取预设文件失败，将使用空列表。`n$($_.Exception.Message)",
            "读取失败",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return @()
    }
}

function Save-Presets([object[]]$presets) {
    $json = $presets | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath $script:PresetFile -Value $json -Encoding UTF8
}

function Get-CurrentConfig([string]$adapterName) {
    $ip = Get-NetIPAddress -InterfaceAlias $adapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne "127.0.0.1" } |
        Sort-Object PrefixOrigin |
        Select-Object -First 1

    $gateway = Get-NetRoute -InterfaceAlias $adapterName -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric |
        Select-Object -First 1

    $dns = Get-DnsClientServerAddress -InterfaceAlias $adapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue

    [pscustomobject]@{
        Adapter = $adapterName
        IPAddress = if ($ip) { $ip.IPAddress } else { "" }
        PrefixLength = if ($ip) { [string]$ip.PrefixLength } else { "" }
        Gateway = if ($gateway) { $gateway.NextHop } else { "" }
        Dns = if ($dns -and $dns.ServerAddresses) { ($dns.ServerAddresses -join ", ") } else { "" }
        IsDhcp = if ($ip) { $ip.PrefixOrigin -eq "Dhcp" } else { $false }
    }
}

function Apply-StaticConfig([string]$adapterName, [string]$ip, [string]$prefixLength, [string]$gateway, [string]$dnsText) {
    $netmask = Convert-PrefixToMask $prefixLength
    $gatewayArg = if ([string]::IsNullOrWhiteSpace($gateway)) { "none" } else { $gateway }
    netsh interface ip set address name="$adapterName" static $ip $netmask $gatewayArg 1 | Out-Null

    if ([string]::IsNullOrWhiteSpace($dnsText)) {
        netsh interface ip set dns name="$adapterName" dhcp | Out-Null
        return
    }

    $dnsServers = $dnsText.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($dnsServers.Count -eq 0) {
        netsh interface ip set dns name="$adapterName" dhcp | Out-Null
        return
    }

    netsh interface ip set dns name="$adapterName" static $dnsServers[0] primary | Out-Null
    for ($i = 1; $i -lt $dnsServers.Count; $i++) {
        $indexArg = "index={0}" -f ($i + 1)
        netsh interface ip add dns name="$adapterName" $dnsServers[$i] $indexArg | Out-Null
    }
}

function Apply-DhcpConfig([string]$adapterName) {
    netsh interface ip set address name="$adapterName" dhcp | Out-Null
    netsh interface ip set dns name="$adapterName" dhcp | Out-Null
}

function Convert-PrefixToMask([string]$prefixLength) {
    $prefix = [int]$prefixLength
    $mask = [uint32]0
    for ($i = 0; $i -lt $prefix; $i++) {
        $mask = $mask -bor (1 -shl (31 - $i))
    }

    $bytes = [BitConverter]::GetBytes([uint32]$mask)
    [Array]::Reverse($bytes)
    return ($bytes | ForEach-Object { [string]$_ }) -join "."
}

function Validate-IPv4([string]$value, [bool]$allowEmpty = $false) {
    if ($allowEmpty -and [string]::IsNullOrWhiteSpace($value)) {
        return $true
    }

    $nullIp = [System.Net.IPAddress]::None
    return [System.Net.IPAddress]::TryParse($value, [ref]$nullIp)
}

if (-not (Ensure-Elevated)) {
    return
}

$script:Presets = Get-Presets

$form = New-Object System.Windows.Forms.Form
$form.Text = "IP 一键切换"
$form.Size = New-Object System.Drawing.Size(760, 520)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$form.Font = $font

$labelAdapter = New-Object System.Windows.Forms.Label
$labelAdapter.Text = "网卡"
$labelAdapter.Location = New-Object System.Drawing.Point(20, 20)
$labelAdapter.AutoSize = $true
$form.Controls.Add($labelAdapter)

$comboAdapter = New-Object System.Windows.Forms.ComboBox
$comboAdapter.Location = New-Object System.Drawing.Point(80, 16)
$comboAdapter.Size = New-Object System.Drawing.Size(330, 28)
$comboAdapter.DropDownStyle = "DropDownList"
$form.Controls.Add($comboAdapter)

$buttonRefreshAdapters = New-Object System.Windows.Forms.Button
$buttonRefreshAdapters.Text = "刷新网卡"
$buttonRefreshAdapters.Location = New-Object System.Drawing.Point(430, 14)
$buttonRefreshAdapters.Size = New-Object System.Drawing.Size(100, 32)
$form.Controls.Add($buttonRefreshAdapters)

$buttonLoadCurrent = New-Object System.Windows.Forms.Button
$buttonLoadCurrent.Text = "读取当前配置"
$buttonLoadCurrent.Location = New-Object System.Drawing.Point(545, 14)
$buttonLoadCurrent.Size = New-Object System.Drawing.Size(150, 32)
$form.Controls.Add($buttonLoadCurrent)

$presetGroup = New-Object System.Windows.Forms.GroupBox
$presetGroup.Text = "已保存预设"
$presetGroup.Location = New-Object System.Drawing.Point(20, 65)
$presetGroup.Size = New-Object System.Drawing.Size(250, 390)
$form.Controls.Add($presetGroup)

$listPresets = New-Object System.Windows.Forms.ListBox
$listPresets.Location = New-Object System.Drawing.Point(15, 30)
$listPresets.Size = New-Object System.Drawing.Size(215, 260)
$presetGroup.Controls.Add($listPresets)

$buttonApplyPreset = New-Object System.Windows.Forms.Button
$buttonApplyPreset.Text = "应用预设"
$buttonApplyPreset.Location = New-Object System.Drawing.Point(15, 305)
$buttonApplyPreset.Size = New-Object System.Drawing.Size(100, 34)
$presetGroup.Controls.Add($buttonApplyPreset)

$buttonDeletePreset = New-Object System.Windows.Forms.Button
$buttonDeletePreset.Text = "删除预设"
$buttonDeletePreset.Location = New-Object System.Drawing.Point(130, 305)
$buttonDeletePreset.Size = New-Object System.Drawing.Size(100, 34)
$presetGroup.Controls.Add($buttonDeletePreset)

$buttonSetDhcp = New-Object System.Windows.Forms.Button
$buttonSetDhcp.Text = "切到自动获取"
$buttonSetDhcp.Location = New-Object System.Drawing.Point(15, 348)
$buttonSetDhcp.Size = New-Object System.Drawing.Size(215, 32)
$presetGroup.Controls.Add($buttonSetDhcp)

$editGroup = New-Object System.Windows.Forms.GroupBox
$editGroup.Text = "当前编辑"
$editGroup.Location = New-Object System.Drawing.Point(290, 65)
$editGroup.Size = New-Object System.Drawing.Size(430, 390)
$form.Controls.Add($editGroup)

$labels = @(
    @{ Text = "预设名称"; Y = 35 },
    @{ Text = "IP 地址"; Y = 85 },
    @{ Text = "前缀长度"; Y = 135 },
    @{ Text = "网关"; Y = 185 },
    @{ Text = "DNS"; Y = 235 }
)

foreach ($item in $labels) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $item.Text
    $label.Location = New-Object System.Drawing.Point(20, $item.Y)
    $label.AutoSize = $true
    $editGroup.Controls.Add($label)
}

$textPresetName = New-Object System.Windows.Forms.TextBox
$textPresetName.Location = New-Object System.Drawing.Point(110, 30)
$textPresetName.Size = New-Object System.Drawing.Size(290, 28)
$editGroup.Controls.Add($textPresetName)

$textIp = New-Object System.Windows.Forms.TextBox
$textIp.Location = New-Object System.Drawing.Point(110, 80)
$textIp.Size = New-Object System.Drawing.Size(290, 28)
$editGroup.Controls.Add($textIp)

$textPrefix = New-Object System.Windows.Forms.TextBox
$textPrefix.Location = New-Object System.Drawing.Point(110, 130)
$textPrefix.Size = New-Object System.Drawing.Size(290, 28)
$textPrefix.Text = "24"
$editGroup.Controls.Add($textPrefix)

$textGateway = New-Object System.Windows.Forms.TextBox
$textGateway.Location = New-Object System.Drawing.Point(110, 180)
$textGateway.Size = New-Object System.Drawing.Size(290, 28)
$editGroup.Controls.Add($textGateway)

$textDns = New-Object System.Windows.Forms.TextBox
$textDns.Location = New-Object System.Drawing.Point(110, 230)
$textDns.Size = New-Object System.Drawing.Size(290, 28)
$editGroup.Controls.Add($textDns)

$labelHint = New-Object System.Windows.Forms.Label
$labelHint.Text = "DNS 多个地址用逗号分开，例如 223.5.5.5, 114.114.114.114"
$labelHint.Location = New-Object System.Drawing.Point(20, 270)
$labelHint.Size = New-Object System.Drawing.Size(380, 35)
$editGroup.Controls.Add($labelHint)

$buttonSavePreset = New-Object System.Windows.Forms.Button
$buttonSavePreset.Text = "保存预设"
$buttonSavePreset.Location = New-Object System.Drawing.Point(20, 325)
$buttonSavePreset.Size = New-Object System.Drawing.Size(110, 34)
$editGroup.Controls.Add($buttonSavePreset)

$buttonApplyCustom = New-Object System.Windows.Forms.Button
$buttonApplyCustom.Text = "应用当前填写"
$buttonApplyCustom.Location = New-Object System.Drawing.Point(145, 325)
$buttonApplyCustom.Size = New-Object System.Drawing.Size(130, 34)
$editGroup.Controls.Add($buttonApplyCustom)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "准备就绪"
$statusLabel.Location = New-Object System.Drawing.Point(20, 465)
$statusLabel.Size = New-Object System.Drawing.Size(700, 24)
$form.Controls.Add($statusLabel)

$script:EditingPresetIndex = -1

function Set-Status([string]$text) {
    $statusLabel.Text = $text
}

function Refresh-AdapterList {
    $selected = $comboAdapter.SelectedItem
    $comboAdapter.Items.Clear()
    $adapters = Get-ActiveAdapters
    foreach ($adapter in $adapters) {
        [void]$comboAdapter.Items.Add($adapter)
    }

    if ($selected -and $comboAdapter.Items.Contains($selected)) {
        $comboAdapter.SelectedItem = $selected
    }
    elseif ($comboAdapter.Items.Count -gt 0) {
        $comboAdapter.SelectedIndex = 0
    }
}

function Refresh-PresetList {
    $selectedName = if ($listPresets.SelectedIndex -ge 0 -and $listPresets.SelectedIndex -lt $script:Presets.Count) {
        $script:Presets[$listPresets.SelectedIndex].Name
    }
    else {
        $null
    }

    $listPresets.Items.Clear()
    foreach ($preset in $script:Presets) {
        [void]$listPresets.Items.Add($preset.Name)
    }

    if ($selectedName) {
        $index = [Array]::IndexOf(@($script:Presets.Name), $selectedName)
        if ($index -ge 0) {
            $listPresets.SelectedIndex = $index
            $script:EditingPresetIndex = $index
        }
    }
}

function Fill-FormFromPreset($preset) {
    $textPresetName.Text = $preset.Name
    $textIp.Text = $preset.IPAddress
    $textPrefix.Text = [string]$preset.PrefixLength
    $textGateway.Text = $preset.Gateway
    $textDns.Text = $preset.Dns
}

function Get-SelectedAdapter {
    if (-not $comboAdapter.SelectedItem) {
        throw "请选择网卡。"
    }

    return [string]$comboAdapter.SelectedItem
}

function Validate-Form {
    if (-not (Validate-IPv4 $textIp.Text)) {
        throw "IP 地址格式不正确。"
    }

    $prefix = 0
    if (-not [int]::TryParse($textPrefix.Text, [ref]$prefix) -or $prefix -lt 1 -or $prefix -gt 32) {
        throw "前缀长度请输入 1 到 32。"
    }

    if (-not (Validate-IPv4 $textGateway.Text $true)) {
        throw "网关格式不正确。"
    }

    $dnsServers = $textDns.Text.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    foreach ($dns in $dnsServers) {
        if (-not (Validate-IPv4 $dns)) {
            throw "DNS 地址格式不正确：$dns"
        }
    }
}

$buttonRefreshAdapters.Add_Click({
    Refresh-AdapterList
    Set-Status "网卡列表已刷新。"
})

$buttonLoadCurrent.Add_Click({
    try {
        $adapter = Get-SelectedAdapter
        $config = Get-CurrentConfig $adapter
        $textIp.Text = $config.IPAddress
        $textPrefix.Text = if ($config.PrefixLength) { $config.PrefixLength } else { "24" }
        $textGateway.Text = $config.Gateway
        $textDns.Text = $config.Dns
        Set-Status "已读取 $adapter 的当前配置。"
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "读取失败") | Out-Null
    }
})

$listPresets.Add_SelectedIndexChanged({
    $index = $listPresets.SelectedIndex
    if ($index -ge 0) {
        $script:EditingPresetIndex = $index
        Fill-FormFromPreset $script:Presets[$index]
    }
    else {
        $script:EditingPresetIndex = -1
    }
})

$buttonSavePreset.Add_Click({
    try {
        Validate-Form
        $name = $textPresetName.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "请填写预设名称。"
        }

        $editingIndex = $script:EditingPresetIndex
        $duplicateIndex = -1
        for ($i = 0; $i -lt $script:Presets.Count; $i++) {
            if ($script:Presets[$i].Name -eq $name) {
                $duplicateIndex = $i
                break
            }
        }

        if ($duplicateIndex -ge 0 -and $duplicateIndex -ne $editingIndex) {
            throw "已经存在同名预设，请换一个名称。"
        }

        if ($editingIndex -ge 0 -and $editingIndex -lt $script:Presets.Count) {
            $script:Presets[$editingIndex].Name = $name
            $script:Presets[$editingIndex].IPAddress = $textIp.Text.Trim()
            $script:Presets[$editingIndex].PrefixLength = [int]$textPrefix.Text.Trim()
            $script:Presets[$editingIndex].Gateway = $textGateway.Text.Trim()
            $script:Presets[$editingIndex].Dns = $textDns.Text.Trim()
        }
        else {
            $script:Presets += [pscustomobject]@{
                Name = $name
                IPAddress = $textIp.Text.Trim()
                PrefixLength = [int]$textPrefix.Text.Trim()
                Gateway = $textGateway.Text.Trim()
                Dns = $textDns.Text.Trim()
            }
        }

        Save-Presets $script:Presets
        Refresh-PresetList
        $selectedIndex = [Array]::IndexOf(@($script:Presets.Name), $name)
        if ($selectedIndex -ge 0) {
            $listPresets.SelectedIndex = $selectedIndex
            $script:EditingPresetIndex = $selectedIndex
        }
        Set-Status "预设已保存：$name"
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "保存失败") | Out-Null
    }
})

$buttonDeletePreset.Add_Click({
    $index = $listPresets.SelectedIndex
    if ($index -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("请先选中一个预设。", "提示") | Out-Null
        return
    }

    $name = $script:Presets[$index].Name
    $script:Presets = @($script:Presets | Where-Object { $_.Name -ne $name })
    Save-Presets $script:Presets
    $script:EditingPresetIndex = -1
    Refresh-PresetList
    Set-Status "预设已删除：$name"
})

$buttonApplyCustom.Add_Click({
    try {
        Validate-Form
        $adapter = Get-SelectedAdapter
        Apply-StaticConfig $adapter $textIp.Text.Trim() $textPrefix.Text.Trim() $textGateway.Text.Trim() $textDns.Text.Trim()
        Set-Status "已应用静态 IP 到 $adapter"
        [System.Windows.Forms.MessageBox]::Show("IP 已切换完成。", "成功") | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "应用失败") | Out-Null
    }
})

$buttonApplyPreset.Add_Click({
    $index = $listPresets.SelectedIndex
    if ($index -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("请先选中一个预设。", "提示") | Out-Null
        return
    }

    try {
        $adapter = Get-SelectedAdapter
        $preset = $script:Presets[$index]
        Apply-StaticConfig $adapter $preset.IPAddress ([string]$preset.PrefixLength) $preset.Gateway $preset.Dns
        Fill-FormFromPreset $preset
        Set-Status "已应用预设：$($preset.Name)"
        [System.Windows.Forms.MessageBox]::Show("预设已应用。", "成功") | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "应用失败") | Out-Null
    }
})

$buttonSetDhcp.Add_Click({
    try {
        $adapter = Get-SelectedAdapter
        Apply-DhcpConfig $adapter
        Set-Status "已切换为自动获取：$adapter"
        [System.Windows.Forms.MessageBox]::Show("已切换为自动获取 IP。", "成功") | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "切换失败") | Out-Null
    }
})

Refresh-AdapterList
Refresh-PresetList

[void]$form.ShowDialog()
