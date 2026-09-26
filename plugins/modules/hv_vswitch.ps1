#!powershell

# Copyright (c) 2026, Ansible Cloud Team (@ansible)
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ansible_collections.microsoft.hyperv.plugins.module_utils.HyperV

$spec = @{
    options = @{
        name = @{ type = "str"; required = $true }
        state = @{ type = "str"; default = "present"; choices = @("present", "absent") }
        switch_type = @{ type = "str"; choices = @("external", "internal", "private") }
        net_adapter_names = @{ type = "list"; elements = "str" }
        allow_management_os = @{ type = "bool" }
        enable_embedded_teaming = @{ type = "bool" }
        enable_iov = @{ type = "bool" }
        minimum_bandwidth_mode = @{ type = "str"; choices = @("None", "Absolute", "Weight", "Default") }
        default_flow_minimum_bandwidth_absolute = @{ type = "raw" }
        default_flow_minimum_bandwidth_weight = @{ type = "int" }
        notes = @{ type = "str" }
        extensions = @{ type = "list"; elements = "dict" }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$name = $module.Params.name
$state = $module.Params.state
$switch_type = $module.Params.switch_type
$net_adapter_names = $module.Params.net_adapter_names
$allow_management_os = $module.Params.allow_management_os
$enable_embedded_teaming = $module.Params.enable_embedded_teaming
$enable_iov = $module.Params.enable_iov
$minimum_bandwidth_mode = $module.Params.minimum_bandwidth_mode
$default_flow_minimum_bandwidth_absolute = $module.Params.default_flow_minimum_bandwidth_absolute
$notes = $module.Params.notes
$extensions = $module.Params.extensions

if ($null -ne $default_flow_minimum_bandwidth_absolute) {
    $default_flow_minimum_bandwidth_absolute = Convert-ToByte -SizeString $default_flow_minimum_bandwidth_absolute
}

$module.Result.name = $name
$module.Result.state = $state

# Define the mapping between Ansible params and Hyper-V properties.
#
# Immutable = $true means the property is only used for drift *detection* / result
# *reporting* and is excluded from the hashtable Get-HyperVParametersFromMap builds
# for Set-VMSwitch, because Set-VMSwitch does not actually support changing it after
# switch creation (enable_iov, minimum_bandwidth_mode, enable_embedded_teaming are all
# creation-only parameters on New-VMSwitch that Set-VMSwitch simply doesn't expose).
#
# net_adapter_names is deliberately NOT resolved generically here: Get-VMSwitch reports
# NetAdapterInterfaceDescriptions (hardware descriptions), while the user supplies
# friendly adapter Names, so a raw comparison would always report false drift. It's
# handled explicitly below instead, and kept in this map only so the reporting helpers
# (Set-HyperVResultFromMap / the check-mode echo loop) can still surface its current value.
$propertyMap = @(
    # Never sent to Set-VMSwitch: switch_type is already validated as immutable above
    # (FailJson on mismatch before this map is ever used to build a Set-VMSwitch call).
    # -SwitchType and -NetAdapterInterfaceDescription are mutually exclusive Set-VMSwitch
    # parameter sets, so leaving -SwitchType out is required, not just tidy - including it
    # unconditionally (as this playbook always passes switch_type) broke every adapter
    # reassignment with "Parameter set cannot be resolved using the specified named parameters."
    @{ Param = "switch_type"; Property = "SwitchType"; Type = "enum"; Immutable = $true }
    @{ Param = "notes"; Property = "Notes"; Type = "string" }
    @{ Param = "allow_management_os"; Property = "AllowManagementOS"; Type = "bool"; SwitchType = "External" }
    @{ Param = "enable_iov"; Property = "IovEnabled"; CmdletParam = "EnableIov"; Type = "bool"; Immutable = $true }
    @{ Param = "minimum_bandwidth_mode"; Property = "MinimumBandwidthMode"; Type = "enum"; Immutable = $true }
    @{ Param = "default_flow_minimum_bandwidth_absolute"; Property = "DefaultFlowMinimumBandwidthAbsolute"; Type = "long" }
    @{ Param = "default_flow_minimum_bandwidth_weight"; Property = "DefaultFlowMinimumBandwidthWeight"; Type = "int" }
    @{ Param = "enable_embedded_teaming"; Property = "EmbeddedTeamingEnabled"; Type = "bool"; SwitchType = "External"; Immutable = $true }
    @{ Param = "net_adapter_names"; Property = "NetAdapterInterfaceDescriptions"; Type = "list"; SwitchType = "External"; Immutable = $true }
)

# The subset of the map that's safe to feed into generic drift-detection / Set-VMSwitch
# param-building. net_adapter_names is excluded entirely (handled manually below) since
# comparing friendly names against hardware descriptions would always look "changed".
$diffMap = $propertyMap | Where-Object { $_.Param -ne "net_adapter_names" }

try {
    $vswitch = Get-VMSwitch -Name $name -ErrorAction SilentlyContinue

    if ($state -eq "absent") {
        if ($null -eq $vswitch) {
            $module.ExitJson()
        }

        $module.Result.changed = $true
        if ($module.CheckMode) {
            $module.ExitJson()
        }

        Remove-VMSwitch -Name $name -Force
        $module.ExitJson()
    }

    $changed = $false
    $creation_required = ($null -eq $vswitch)
    $adapter_changed = $false
    $resolved_adapter_descriptions = @()

    if ($creation_required) {
        if ($null -eq $switch_type) {
            $module.FailJson("Parameter 'switch_type' is required when creating a new virtual switch.")
        }

        if ($switch_type -eq "external") {
            if ($null -eq $net_adapter_names -or $net_adapter_names.Count -eq 0) {
                $module.FailJson("Parameter 'net_adapter_names' is required for external switches.")
            }
            if ($net_adapter_names.Count -gt 1 -and $enable_embedded_teaming -eq $false) {
                $module.FailJson("Cannot set 'enable_embedded_teaming' to false when multiple 'net_adapter_names' are provided.")
            }
        }
        else {
            if ($null -ne $net_adapter_names -and $net_adapter_names.Count -gt 0) {
                $module.Warn("'net_adapter_names' is ignored for '$switch_type' switches.")
            }
            if ($null -ne $allow_management_os) {
                $module.Warn("'allow_management_os' is ignored for '$switch_type' switches.")
            }
            if ($null -ne $enable_embedded_teaming) {
                $module.Warn("'enable_embedded_teaming' is ignored for '$switch_type' switches.")
            }
        }

        $changed = $true
    }
    else {
        $vType = $vswitch.SwitchType.ToString().ToLower()
        if ($null -ne $switch_type -and
            $vType -ne $switch_type.ToLower()) {
            $msg = "Cannot change switch_type. Current: $($vswitch.SwitchType)"
            $module.FailJson($msg)
        }

        # The following are all fixed at switch-creation time and are not exposed by
        # Set-VMSwitch at all. Fail loudly on a genuine attempted change instead of
        # silently no-op'ing it, which would otherwise report changed=true forever.
        if ($null -ne $enable_iov -and $enable_iov -ne $vswitch.IovEnabled) {
            $module.FailJson("Cannot change 'enable_iov' on an existing switch (current: $($vswitch.IovEnabled)). " +
                "SR-IOV mode is fixed at creation time - set state=absent then present to recreate the switch.")
        }
        $current_bandwidth_mode = if ($null -ne $vswitch.MinimumBandwidthMode) {
            $vswitch.MinimumBandwidthMode.ToString()
        }
        else {
            ""
        }
        if ($null -ne $minimum_bandwidth_mode -and $minimum_bandwidth_mode -ne $current_bandwidth_mode) {
            $module.FailJson("Cannot change 'minimum_bandwidth_mode' on an existing switch (current: $($vswitch.MinimumBandwidthMode)). " +
                "This is fixed at creation time - set state=absent then present to recreate the switch.")
        }
        if ($vType -eq "external" -and $null -ne $enable_embedded_teaming -and $enable_embedded_teaming -ne $vswitch.EmbeddedTeamingEnabled) {
            $module.FailJson("Cannot change 'enable_embedded_teaming' on an existing switch (current: $($vswitch.EmbeddedTeamingEnabled)). " +
                "This is fixed at creation time - set state=absent then present to recreate the switch.")
        }

        # Resolve desired adapter friendly Names to InterfaceDescriptions so they can be
        # compared apples-to-apples against $vswitch.NetAdapterInterfaceDescriptions.
        if ($vType -eq "external" -and $null -ne $net_adapter_names -and $net_adapter_names.Count -gt 0) {
            foreach ($an in $net_adapter_names) {
                $adapter_matches = @(Get-NetAdapter -Name $an -ErrorAction SilentlyContinue)
                if ($adapter_matches.Count -eq 0) {
                    $module.FailJson("Network adapter '$an' was not found on this host.")
                }
                if ($adapter_matches.Count -gt 1) {
                    $module.FailJson("Network adapter name '$an' is ambiguous - $($adapter_matches.Count) adapters matched on this host.")
                }
                # Force a plain string: without this, an ambiguous/array-shaped result
                # could silently nest inside the array via '+=' and make the join-based
                # comparison below never match, permanently reporting false drift.
                $resolved_adapter_descriptions += [string]$adapter_matches[0].InterfaceDescription
            }

            $current_descriptions = @([string[]]$vswitch.NetAdapterInterfaceDescriptions | Sort-Object)
            $desired_descriptions = @([string[]]$resolved_adapter_descriptions | Sort-Object)
            $adapter_changed = (($current_descriptions -join ",") -ne ($desired_descriptions -join ","))

            if ($adapter_changed) {
                $module.Warn("net_adapter_names drift detected for '$name': " +
                    "current=[$($current_descriptions -join ', ')] " +
                    "desired=[$($desired_descriptions -join ', ')]")
            }
        }

        $changed = (Test-HyperVPropertiesChanged -PropertyMap $diffMap -CurrentObject $vswitch `
                -AnsibleParams $module.Params -SwitchType $vswitch.SwitchType.ToString()) -or $adapter_changed

        if ($null -ne $extensions) {
            $current_extensions = @(Get-VMSwitchExtension -VMSwitchName $name)
            foreach ($ext_spec in $extensions) {
                $ext_name = $ext_spec.name
                $ext_state = $ext_spec.state
                $ext_obj = $current_extensions | Where-Object { $_.Name -eq $ext_name -or $_.Id -eq $ext_name }

                # Always validate the extension exists, regardless of whether other
                # properties already flagged a change - don't let an earlier diff mask
                # a typo'd extension name until apply time.
                if ($null -eq $ext_obj) {
                    $module.FailJson("Extension '$ext_name' not found on switch '$name'.")
                }

                if (-not $changed) {
                    if ($ext_state -eq "enabled" -and -not $ext_obj.Enabled) {
                        $changed = $true
                    }
                    elseif ($ext_state -eq "disabled" -and $ext_obj.Enabled) {
                        $changed = $true
                    }
                }
            }
        }
    }

    $module.Result.changed = $changed

    if ($module.CheckMode) {
        if ($creation_required) {
            $module.Result.switch_type = $switch_type
            if ($null -ne $enable_iov) { $module.Result.enable_iov = $enable_iov }
        }
        else {
            Set-HyperVResultFromMap -PropertyMap $propertyMap -CurrentObject $vswitch -ModuleResult $module.Result
            # Override with desired state
            foreach ($map in $propertyMap) {
                $paramValue = $module.Params.($map.Param)
                if ($null -ne $paramValue) {
                    $module.Result.($map.Param) = $paramValue
                }
            }
        }
        $module.ExitJson()
    }

    if ($changed) {
        if ($creation_required) {
            $new_params = @{
                Name = $name
            }

            if ($null -ne $notes) {
                $new_params.Notes = $notes
            }

            if ($enable_iov -eq $true) {
                $new_params.EnableIov = $true
            }

            if ($null -ne $minimum_bandwidth_mode) {
                $new_params.MinimumBandwidthMode = $minimum_bandwidth_mode
            }

            switch ($switch_type) {
                "external" {
                    if ($net_adapter_names.Count -eq 1) {
                        $new_params.NetAdapterName = [string]$net_adapter_names[0]
                    }
                    else {
                        $new_params.NetAdapterName = [string[]]$net_adapter_names
                        $new_params.EnableEmbeddedTeaming = $true
                    }

                    if ($null -ne $allow_management_os) {
                        $new_params.AllowManagementOS = $allow_management_os
                    }
                    if ($null -ne $enable_embedded_teaming) {
                        $new_params.EnableEmbeddedTeaming = $enable_embedded_teaming
                    }
                }
                "internal" {
                    $new_params.SwitchType = "Internal"
                }
                "private" {
                    $new_params.SwitchType = "Private"
                }
            }

            New-VMSwitch @new_params | Out-Null
            $vswitch = Get-VMSwitch -Name $name
        }
        else {
            # Set-VMSwitch has no -VMSwitch + -NetAdapterName parameter set; -Name works
            # across every parameter set it does support, so use it as the common base.
            $set_params = @{
                Name = $name
            }
            $set_params += Get-HyperVParametersFromMap -PropertyMap $diffMap `
                -AnsibleParams $module.Params -SwitchType $vswitch.SwitchType.ToString()

            if ($adapter_changed) {
                if ($resolved_adapter_descriptions.Count -ne 1) {
                    $module.FailJson("Changing to multiple net_adapter_names on an existing switch is not supported by Set-VMSwitch; " +
                        "set state=absent then present to recreate the switch instead.")
                }
                $set_params.NetAdapterInterfaceDescription = $resolved_adapter_descriptions[0]
            }

            if ($set_params.Count -gt 1) {
                Set-VMSwitch @set_params | Out-Null
            }
        }

        if ($null -ne $extensions) {
            $current_extensions = @(Get-VMSwitchExtension -VMSwitchName $name)
            foreach ($ext_spec in $extensions) {
                $ext_name = $ext_spec.name
                $ext_state = $ext_spec.state
                $ext_obj = $current_extensions | Where-Object { $_.Name -eq $ext_name -or $_.Id -eq $ext_name }

                if ($null -eq $ext_obj) {
                    $module.FailJson("Extension '$ext_name' not found on switch '$name'.")
                }

                if ($ext_state -eq "enabled" -and -not $ext_obj.Enabled) {
                    Enable-VMSwitchExtension -VMSwitchName $name -Name $ext_name | Out-Null
                }
                elseif ($ext_state -eq "disabled" -and $ext_obj.Enabled) {
                    Disable-VMSwitchExtension -VMSwitchName $name -Name $ext_name | Out-Null
                }
            }
        }
    }

    # Final result mapping
    $final_vswitch = Get-VMSwitch -Name $name -ErrorAction SilentlyContinue
    if ($null -ne $final_vswitch) {
        Set-HyperVResultFromMap -PropertyMap $propertyMap -CurrentObject $final_vswitch -ModuleResult $module.Result

        $bw_mode = switch ([int]$final_vswitch.MinimumBandwidthMode) {
            0 { "None" }
            1 { "Absolute" }
            2 { "Weight" }
            3 { "Default" }
            default { $final_vswitch.MinimumBandwidthMode.ToString() }
        }
        $module.Result.minimum_bandwidth_mode = $bw_mode
    }

    $module.ExitJson()
}
catch {
    $module.FailJson("Failed to manage virtual switch: $($_.Exception.Message)")
}
