# RadiusMax Remote Device Gateway RC installer
# Release candidate: v0.8.0-rc1-installer1
# Immutable image: ghcr.io/mushtaqraad78-arch/radiusmax-agent:v0.8.0-rc1@sha256:b783104b94c8c912f41103748ad8932acef83b2e032469d3127df9c080f07267
# This script never changes PPP, RADIUS, subscriber, or route configuration.
# It adds only the dedicated Agent network, input allow, and source-NAT objects below.

{
    :local rmxInstallerVersion "v0.8.0-rc1-installer1";
    :local rmxManagedComment "RADIUSMAX-PHASE7F-MANAGED";
    :local rmxContainerName "radiusmax-agent";
    :local rmxImage "mushtaqraad78-arch/radiusmax-agent:v0.8.0-rc1@sha256:b783104b94c8c912f41103748ad8932acef83b2e032469d3127df9c080f07267";
    :local rmxImageFull "ghcr.io/mushtaqraad78-arch/radiusmax-agent:v0.8.0-rc1@sha256:b783104b94c8c912f41103748ad8932acef83b2e032469d3127df9c080f07267";
    # Quoted custom identifier avoids the RouterOS 7.24.2 external-source parser
    # rejecting the old bare rmxGateway declaration at block line 7 column 17.
    :local "rmxCentralURL";
    :set "rmxCentralURL" "ws://167.86.73.203:8080/ws";
    :local rmxBridge "radiusmax-agent-br";
    :local rmxVeth "radiusmax-agent-veth";
    :local rmxRouterAddress "172.31.255.1/30";
    :local rmxRouterIP "172.31.255.1";
    :local rmxAgentAddress "172.31.255.2/30";
    :local rmxAgentIP "172.31.255.2";
    :local rmxNetwork "172.31.255.0/30";
    :local rmxRemoteDeviceDenyCIDRs "172.31.255.0/30";
    :local rmxUser "radiusmax-agent";
    :local rmxGroup "radiusmax-agent-7f";
    :local rmxEnvList "radiusmax-agent-env";
    :local rmxMountList "radiusmax-agent-state";
    :local rmxMinFree 134217728;

    :put ("RadiusMax installer " . $rmxInstallerVersion . " starting");

    # PHASE 1: READ-ONLY PREFLIGHT. No configuration mutations occur before the pass message.
    # A complete managed installation is a no-op. Never touch its state or credentials.
    :local rmxExistingContainer [/container find where name=$rmxContainerName];
    :if ([:len $rmxExistingContainer] > 1) do={
        :error "RadiusMax: multiple containers use the managed name; no changes made";
    };
    :if ([:len $rmxExistingContainer] = 1) do={
        :local rmxExistingComment [/container get $rmxExistingContainer comment];
        :if ($rmxExistingComment != $rmxManagedComment) do={
            :error "RadiusMax: container name already belongs to an unmanaged object; no changes made";
        };
        :local rmxExistingStatus [/container get $rmxExistingContainer status];
        :if (($rmxExistingStatus ~ "failed") or ($rmxExistingStatus ~ "error")) do={
            :error ("RadiusMax: managed container exists in failed partial-install state (" . $rmxExistingStatus . "); inspect and remove only that failed container before retrying");
        };
        :if (($rmxExistingStatus ~ "download") or ($rmxExistingStatus ~ "extract") or ($rmxExistingStatus ~ "delet")) do={
            :error ("RadiusMax: managed container operation is still in progress (" . $rmxExistingStatus . "); wait and inspect before retrying");
        };
        :put "RadiusMax already installed/no-op: existing container and enrolled state were left unchanged.";
        :put "Use /container/print detail where name=radiusmax-agent to inspect status.";
        # :exit is the RouterOS 7.22+ command for terminating the imported script.
        :exit;
    };

    # RouterOS 7.23 is required for the current container restart-policy controls.
    :local rmxROSVersion [/system resource get version];
    :local rmxSpace [:find $rmxROSVersion " "];
    :if ([:typeof $rmxSpace] != "nil") do={ :set rmxROSVersion [:pick $rmxROSVersion 0 $rmxSpace] };
    :local rmxDot1 [:find $rmxROSVersion "."];
    :if ([:typeof $rmxDot1] = "nil") do={ :error ("RadiusMax: cannot parse RouterOS version " . $rmxROSVersion) };
    :local rmxMajor [:tonum [:pick $rmxROSVersion 0 $rmxDot1]];
    :local rmxRest [:pick $rmxROSVersion ($rmxDot1 + 1) [:len $rmxROSVersion]];
    :local rmxDot2 [:find $rmxRest "."];
    :local rmxMinorText $rmxRest;
    :if ([:typeof $rmxDot2] != "nil") do={ :set rmxMinorText [:pick $rmxRest 0 $rmxDot2] };
    :local rmxMinor [:tonum $rmxMinorText];
    :if (($rmxMajor < 7) or (($rmxMajor = 7) and ($rmxMinor < 23))) do={
        :error ("RadiusMax: RouterOS 7.23 or newer is required; found " . $rmxROSVersion);
    };

    :local rmxArchitecture [/system resource get architecture-name];
    :if (($rmxArchitecture != "arm") and ($rmxArchitecture != "arm64") and ($rmxArchitecture != "x86_64") and ($rmxArchitecture != "amd64")) do={
        :error ("RadiusMax: unsupported architecture " . $rmxArchitecture . "; supported: arm, arm64, x86_64");
    };

    :local rmxContainerPackage [/system package find where name="container"];
    :if ([:len $rmxContainerPackage] = 0) do={
        :error "RadiusMax: RouterOS Container package is not installed";
    };
    :if ([:len $rmxContainerPackage] > 1) do={ :error "RadiusMax: multiple Container package records found" };
    :if ([/system package get $rmxContainerPackage version] != $rmxROSVersion) do={
        :error ("RadiusMax: Container package version must match RouterOS " . $rmxROSVersion);
    };
    :local rmxDNSServers [/ip dns get servers];
    :local rmxDynamicDNSServers [/ip dns get dynamic-servers];
    :local rmxDoHServer [/ip dns get use-doh-server];
    :if (($rmxDNSServers = "") and ($rmxDynamicDNSServers = "") and ($rmxDoHServer = "")) do={
        :error "RadiusMax: no RouterOS DNS resolver is configured for the GHCR image pull";
    };
    :onerror rmxContainerMenuError in={ /container print count-only } do={
        :error ("RadiusMax: Container support is unavailable: " . $rmxContainerMenuError);
    };
    :local rmxContainerMode false;
    :onerror rmxDeviceModeError in={ :set rmxContainerMode [/system device-mode get container] } do={
        :error ("RadiusMax: cannot read device-mode container permission: " . $rmxDeviceModeError);
    };
    :if (($rmxContainerMode != true) and ($rmxContainerMode != "yes")) do={
        :error "RadiusMax: device-mode container permission is disabled. Enable it with physical confirmation, then rerun this installer";
    };
    :local rmxAPIService [/ip service find where name="api"];
    :if ([:len $rmxAPIService] != 1) do={ :error "RadiusMax: RouterOS API service was not found" };
    :if ([/ip service get $rmxAPIService port] != 8728) do={
        :error "RadiusMax: RouterOS API uses a non-default port; no API settings were changed";
    };
    :local rmxGroupID [/user group find where name=$rmxGroup];
    :local rmxInstallMarker [/container envs find where list=$rmxEnvList and key="RADIUSMAX_INSTALLER_VERSION"];
    :if ([:len $rmxInstallMarker] > 1) do={ :error "RadiusMax: duplicate installer ownership markers found" };
    :if ([:len $rmxGroupID] > 1) do={ :error "RadiusMax: duplicate API groups found" };
    :if (([:len $rmxGroupID] = 1) and ([:len $rmxInstallMarker] = 0)) do={
        :error "RadiusMax: API group name exists without an installer ownership marker; refusing to modify it";
    };
    :local rmxPasswordItem [/container envs find where list=$rmxEnvList and key="MIKROTIK_PASSWORD"];
    :if ([:len $rmxPasswordItem] > 1) do={ :error "RadiusMax: duplicate managed API password entries found" };
    :local rmxAPIDisabledSnapshot [/container envs find where list=$rmxEnvList and key="RADIUSMAX_INSTALLER_API_WAS_DISABLED"];
    :local rmxAPIAddressSnapshot [/container envs find where list=$rmxEnvList and key="RADIUSMAX_INSTALLER_API_ORIGINAL_ADDRESS"];
    :if (([:len $rmxAPIDisabledSnapshot] > 1) or ([:len $rmxAPIAddressSnapshot] > 1)) do={
        :error "RadiusMax: duplicate API service restoration metadata found";
    };
    :local rmxUserID [/user find where name=$rmxUser];
    :if ([:len $rmxUserID] > 1) do={ :error "RadiusMax: duplicate API usernames found" };
    :if ([:len $rmxUserID] = 1) do={
        :if ([/user get $rmxUserID group] != $rmxGroup) do={ :error "RadiusMax: API username belongs to another group; refusing to modify it" };
        :if (([/user get $rmxUserID comment] != $rmxManagedComment) or ([/user get $rmxUserID address] != ($rmxAgentIP . "/32"))) do={ :error "RadiusMax: API username is not the expected managed account; refusing to modify it" };
        :if ([:len $rmxPasswordItem] != 1) do={ :error "RadiusMax: existing API user has no matching managed environment credential; refusing to reset it" };
    };

    # Reuse an existing enrollment state if a prior managed container was removed.
    :local rmxStateDir "";
    :local rmxRootDir "";
    :local rmxTmpDir "";
    :local rmxStateFiles [/file find where name~"radiusmax/state/enrollment.json\$"];
    :if ([:len $rmxStateFiles] > 1) do={
        :error "RadiusMax: multiple enrollment states found; refusing to choose or clone an identity";
    };
    :if ([:len $rmxStateFiles] = 1) do={
        :local rmxStateFile [/file get $rmxStateFiles name];
        :set rmxStateDir [:pick $rmxStateFile 0 ([:len $rmxStateFile] - 16)];
        :local rmxBase [:pick $rmxStateDir 0 ([:len $rmxStateDir] - 6)];
        :set rmxRootDir ($rmxBase . "/root");
        :set rmxTmpDir ($rmxBase . "/tmp");
        :put "RadiusMax: existing enrollment state found and will be reused unchanged";
    } else={
        :local rmxStorage "";
        :foreach rmxDiskFile in=[/file find where type="disk"] do={
            :if ($rmxStorage = "") do={
                :local rmxCandidate [/file get $rmxDiskFile name];
                :local rmxDisk [/disk find where slot=$rmxCandidate];
                :if ([:len $rmxDisk] = 1) do={
                    :local rmxFree [/disk get $rmxDisk free];
                    :if ($rmxFree >= $rmxMinFree) do={ :set rmxStorage $rmxCandidate };
                };
            };
        };
        :if ($rmxStorage = "") do={
            :local rmxInternalFree [/system resource get free-hdd-space];
            :if ($rmxInternalFree < $rmxMinFree) do={
                :error "RadiusMax: no mounted storage with at least 128 MiB free; no changes made";
            };
            :set rmxStateDir "radiusmax/state";
            :set rmxRootDir "radiusmax/root";
            :set rmxTmpDir "radiusmax/tmp";
            :put "RadiusMax warning: using internal storage; attached storage is strongly recommended";
        } else={
            :set rmxStateDir ($rmxStorage . "/radiusmax/state");
            :set rmxRootDir ($rmxStorage . "/radiusmax/root");
            :set rmxTmpDir ($rmxStorage . "/radiusmax/tmp");
        };
    };

    # Refuse address-space collisions unless the exact managed bridge/address already exists.
    :local rmxManagedAddress [/ip address find where address=$rmxRouterAddress and interface=$rmxBridge and comment=$rmxManagedComment];
    :if ([:len $rmxManagedAddress] > 1) do={
        :error "RadiusMax: duplicate managed bridge addresses found";
    };
    :if (([:len $rmxManagedAddress] = 0) and ([:len [/ip route find where dst-address=$rmxNetwork]] > 0)) do={
        :error ("RadiusMax: dedicated network " . $rmxNetwork . " conflicts with an existing route; no changes made");
    };

    :local rmxIdentity [/system identity get name];
    :local rmxBoard [/system resource get board-name];
    :local rmxSerial "";
    :onerror rmxSerialError in={ :set rmxSerial [/system routerboard get serial-number] } do={ :set rmxSerial "" };
    :if ($rmxSerial = "") do={
        :onerror rmxLicenseError in={ :set rmxSerial [/system license get software-id] } do={ :set rmxSerial "" };
    };
    :if ($rmxSerial = "") do={ :set rmxSerial "unavailable" };
    :local rmxDeviceIdentity ("mikrotik|identity=" . $rmxIdentity . "|serial=" . $rmxSerial . "|board=" . $rmxBoard . "|arch=" . $rmxArchitecture);
    :local rmxExistingDeviceIdentity [/container envs find where list=$rmxEnvList and key="RADIUSMAX_DEVICE_IDENTITY"];
    :if ([:len $rmxExistingDeviceIdentity] > 1) do={ :error "RadiusMax: duplicate device identity metadata found" };
    :if ([:len $rmxExistingDeviceIdentity] = 1) do={
        :set rmxDeviceIdentity [/container envs get $rmxExistingDeviceIdentity value];
        :put "RadiusMax: preserving existing device identity metadata";
    };

    # Validate every potentially conflicting object before making the first change.
    :local rmxBridgeID [/interface bridge find where name=$rmxBridge];
    :if ([:len $rmxBridgeID] > 1) do={ :error "RadiusMax: duplicate managed bridge names found" };
    :if ([:len $rmxBridgeID] = 1) do={
        :if ([/interface bridge get $rmxBridgeID comment] != $rmxManagedComment) do={ :error "RadiusMax: bridge name collision; refusing to modify it" };
    };

    :local rmxVethID [/interface veth find where name=$rmxVeth];
    :if ([:len $rmxVethID] > 1) do={ :error "RadiusMax: duplicate managed veth names found" };
    :if ([:len $rmxVethID] = 1) do={
        :if ([/interface veth get $rmxVethID comment] != $rmxManagedComment) do={ :error "RadiusMax: veth name collision; refusing to modify it" };
        :if (([/interface veth get $rmxVethID address] != $rmxAgentAddress) or ([/interface veth get $rmxVethID gateway] != $rmxRouterIP)) do={
            :error "RadiusMax: managed veth has unexpected addressing; refusing to overwrite it";
        };
    };

    :local rmxBridgePort [/interface bridge port find where interface=$rmxVeth];
    :if ([:len $rmxBridgePort] > 1) do={ :error "RadiusMax: duplicate managed bridge ports found" };
    :if ([:len $rmxBridgePort] = 1) do={
        :if ([/interface bridge port get $rmxBridgePort bridge] != $rmxBridge) do={ :error "RadiusMax: managed veth belongs to another bridge" };
    };

    :local rmxNATRule [/ip firewall nat find where comment=$rmxManagedComment];
    :if ([:len $rmxNATRule] > 1) do={ :error "RadiusMax: duplicate managed NAT rules found" };
    :if ([:len $rmxNATRule] = 1) do={
        :if (([/ip firewall nat get $rmxNATRule chain] != "srcnat") or ([/ip firewall nat get $rmxNATRule action] != "masquerade") or ([/ip firewall nat get $rmxNATRule src-address] != $rmxNetwork)) do={
            :error "RadiusMax: managed NAT rule has unexpected settings; refusing to overwrite it";
        };
    };

    :local rmxInputRule [/ip firewall filter find where comment=$rmxManagedComment];
    :if ([:len $rmxInputRule] > 1) do={ :error "RadiusMax: duplicate managed input rules found" };
    :if ([:len $rmxInputRule] = 1) do={
        :if (([/ip firewall filter get $rmxInputRule chain] != "input") or ([/ip firewall filter get $rmxInputRule action] != "accept") or ([/ip firewall filter get $rmxInputRule protocol] != "tcp") or ([/ip firewall filter get $rmxInputRule src-address] != $rmxAgentIP) or ([/ip firewall filter get $rmxInputRule dst-address] != $rmxRouterIP) or ([/ip firewall filter get $rmxInputRule dst-port] != "8728")) do={
            :error "RadiusMax: managed input rule has unexpected settings; refusing to overwrite it";
        };
    };

    :local rmxMountID [/container mounts find where list=$rmxMountList];
    :if ([:len $rmxMountID] > 1) do={ :error "RadiusMax: duplicate persistent-state mounts found" };
    :if ([:len $rmxMountID] = 1) do={
        :if (([/container mounts get $rmxMountID src] != $rmxStateDir) or ([/container mounts get $rmxMountID dst] != "/var/lib/radiusmax")) do={
            :error "RadiusMax: existing state mount points elsewhere; refusing to overwrite it";
        };
    };

    :if ([:len $rmxInstallMarker] = 1) do={
        :if ([/container envs get $rmxInstallMarker value] != $rmxInstallerVersion) do={ :error "RadiusMax: installer ownership marker has an unexpected version" };
    };

    :local rmxValidateEnv do={
        :local rmxKey $1;
        :local rmxValue $2;
        :local rmxItems [/container envs find where list="radiusmax-agent-env" and key=$rmxKey];
        :if ([:len $rmxItems] > 1) do={ :error ("RadiusMax: duplicate environment key " . $rmxKey) };
        :if (([:len $rmxItems] = 1) and ([/container envs get $rmxItems value] != $rmxValue)) do={
            :error ("RadiusMax: managed environment key has an unexpected value: " . $rmxKey);
        };
    };
    $rmxValidateEnv "RADIUSMAX_GATEWAY_URL" $"rmxCentralURL";
    $rmxValidateEnv "RADIUSMAX_REMOTE_DEVICE_DENY_CIDRS" $rmxRemoteDeviceDenyCIDRs;
    $rmxValidateEnv "RADIUSMAX_STATE_DIR" "/var/lib/radiusmax";
    $rmxValidateEnv "RADIUSMAX_LOCAL_TARGET" "http://127.0.0.1:8095";
    $rmxValidateEnv "RADIUSMAX_DEVICE_IDENTITY" $rmxDeviceIdentity;
    $rmxValidateEnv "MIKROTIK_HOST" $rmxRouterIP;
    $rmxValidateEnv "MIKROTIK_PORT" "8728";
    $rmxValidateEnv "MIKROTIK_USER" $rmxUser;
    $rmxValidateEnv "MIKROTIK_TLS" "false";
    $rmxValidateEnv "MIKROTIK_READ_ONLY" "false";

    :local rmxConfigRows [/container config print as-value];
    :if ([:len $rmxConfigRows] != 1) do={ :error "RadiusMax: cannot read the singleton Container configuration" };
    :local rmxConfig [:pick $rmxConfigRows 0];
    :local rmxOldRegistry ($rmxConfig->"registry-url");
    :local rmxOldTmp ($rmxConfig->"tmpdir");
    :put ("RadiusMax preflight passed: RouterOS " . $rmxROSVersion . ", architecture " . $rmxArchitecture . ", storage " . $rmxStateDir);

    # PHASE 2: APPLY. From this point forward, create or reuse only RadiusMax-owned objects.
    :if ([:len $rmxBridgeID] = 0) do={
        /interface bridge add name=$rmxBridge protocol-mode=none comment=$rmxManagedComment;
    };
    :if ([:len $rmxVethID] = 0) do={
        /interface veth add name=$rmxVeth address=$rmxAgentAddress gateway=$rmxRouterIP comment=$rmxManagedComment;
    };
    :if ([:len $rmxBridgePort] = 0) do={
        /interface bridge port add bridge=$rmxBridge interface=$rmxVeth comment=$rmxManagedComment;
    };
    :if ([:len $rmxManagedAddress] = 0) do={
        /ip address add address=$rmxRouterAddress interface=$rmxBridge comment=$rmxManagedComment;
    };
    :if ([:len $rmxNATRule] = 0) do={
        /ip firewall nat add chain=srcnat action=masquerade src-address=$rmxNetwork comment=$rmxManagedComment;
    };
    :put "RadiusMax network created/reused: dedicated 172.31.255.0/30 only";

    # Create a source-restricted API account without sensitive/user-management policy.
    :if ([:len $rmxInstallMarker] = 0) do={
        /container envs add list=$rmxEnvList key="RADIUSMAX_INSTALLER_VERSION" value=$rmxInstallerVersion;
    };
    :if ([:len $rmxGroupID] = 0) do={
        /user group add name=$rmxGroup policy=read,write,test,api;
    } else={
        /user group set $rmxGroupID policy=read,write,test,api;
    };

    :local rmxAPIPassword "";
    :if ([:len $rmxPasswordItem] = 1) do={ :set rmxAPIPassword [/container envs get $rmxPasswordItem value] };
    :if ([:len $rmxUserID] > 0) do={
        :put "RadiusMax: existing managed API user will be reused";
    } else={
        :if ($rmxAPIPassword = "") do={
            :set rmxAPIPassword [:rndstr from="ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789" length=40];
            /container envs add list=$rmxEnvList key="MIKROTIK_PASSWORD" value=$rmxAPIPassword;
        };
        /user add name=$rmxUser group=$rmxGroup password=$rmxAPIPassword address=172.31.255.2/32 disabled=no comment=$rmxManagedComment;
    };

    :local rmxAPIWasDisabled [/ip service get $rmxAPIService disabled];
    :local rmxAPIOriginalAddress [/ip service get $rmxAPIService address];
    :if ([:len $rmxAPIDisabledSnapshot] = 0) do={
        /container envs add list=$rmxEnvList key="RADIUSMAX_INSTALLER_API_WAS_DISABLED" value=$rmxAPIWasDisabled;
    };
    :if ([:len $rmxAPIAddressSnapshot] = 0) do={
        /container envs add list=$rmxEnvList key="RADIUSMAX_INSTALLER_API_ORIGINAL_ADDRESS" value=$rmxAPIOriginalAddress;
    };
    :local rmxAPIAddress $rmxAPIOriginalAddress;
    # An empty service address means unrestricted. Preserve that behavior for existing API clients.
    :if ($rmxAPIAddress != "") do={
        :local rmxAPIMatch [:find ("," . $rmxAPIAddress . ",") ("," . $rmxAgentIP . "/32,")];
        :if ([:typeof $rmxAPIMatch] = "nil") do={
            :set rmxAPIAddress ($rmxAPIAddress . "," . $rmxAgentIP . "/32");
        };
    };
    /ip service set $rmxAPIService disabled=no address=$rmxAPIAddress;

    :if ([:len $rmxInputRule] = 0) do={
        :local rmxFirstInput [/ip firewall filter find where chain="input"];
        :if ([:len $rmxFirstInput] > 0) do={
            /ip firewall filter add chain=input action=accept protocol=tcp src-address=$rmxAgentIP dst-address=$rmxRouterIP dst-port=8728 place-before=[:pick $rmxFirstInput 0] comment=$rmxManagedComment;
        } else={
            /ip firewall filter add chain=input action=accept protocol=tcp src-address=$rmxAgentIP dst-address=$rmxRouterIP dst-port=8728 comment=$rmxManagedComment;
        };
    };
    :put "RadiusMax API access created/reused: dedicated source-restricted user and input rule";

    :local rmxEnsureEnv do={
        :local rmxKey $1;
        :local rmxValue $2;
        :local rmxItems [/container envs find where list="radiusmax-agent-env" and key=$rmxKey];
        :if ([:len $rmxItems] = 0) do={
            /container envs add list="radiusmax-agent-env" key=$rmxKey value=$rmxValue;
        } else={
            :if ([:len $rmxItems] > 1) do={ :error ("RadiusMax: duplicate environment key " . $rmxKey) };
            :if ([/container envs get $rmxItems value] != $rmxValue) do={ :error ("RadiusMax: managed environment key has an unexpected value: " . $rmxKey) };
        };
    };
    $rmxEnsureEnv "RADIUSMAX_GATEWAY_URL" $"rmxCentralURL";
    $rmxEnsureEnv "RADIUSMAX_REMOTE_DEVICE_DENY_CIDRS" $rmxRemoteDeviceDenyCIDRs;
    $rmxEnsureEnv "RADIUSMAX_STATE_DIR" "/var/lib/radiusmax";
    $rmxEnsureEnv "RADIUSMAX_LOCAL_TARGET" "http://127.0.0.1:8095";
    $rmxEnsureEnv "RADIUSMAX_DEVICE_IDENTITY" $rmxDeviceIdentity;
    $rmxEnsureEnv "MIKROTIK_HOST" $rmxRouterIP;
    $rmxEnsureEnv "MIKROTIK_PORT" "8728";
    $rmxEnsureEnv "MIKROTIK_USER" $rmxUser;
    $rmxEnsureEnv "MIKROTIK_TLS" "false";
    $rmxEnsureEnv "MIKROTIK_READ_ONLY" "false";

    :if ([:len $rmxMountID] = 0) do={
        /container mounts add list=$rmxMountList src=$rmxStateDir dst="/var/lib/radiusmax";
    };
    :put "RadiusMax persistent state mount created/reused: /var/lib/radiusmax";

    # Temporarily select GHCR for this pull, then restore the previous global container configuration.
    /container config set registry-url="https://ghcr.io" tmpdir=$rmxTmpDir;
    :onerror rmxPullError in={
        /container add remote-image=$rmxImage interface=$rmxVeth root-dir=$rmxRootDir mountlists=$rmxMountList envlists=$rmxEnvList name=$rmxContainerName hostname="radiusmax-agent" start-on-boot=yes restart-policy=always restart-interval=30s check-certificate=yes logging=yes comment=$rmxManagedComment;
        :local rmxNewContainer [/container find where name=$rmxContainerName];
        :local rmxWait 0;
        :while ($rmxWait < 120) do={
            :local rmxStatus [/container get $rmxNewContainer status];
            :if ($rmxStatus = "stopped") do={ :set rmxWait 120 } else={
                :if (($rmxStatus ~ "error") or ($rmxStatus ~ "failed")) do={ :error ("container extraction failed: " . $rmxStatus) };
                :delay 5s;
                :set rmxWait ($rmxWait + 1);
            };
        };
        :if ([/container get $rmxNewContainer status] != "stopped") do={ :error "container extraction timed out" };
    } do={
        /container config set registry-url=$rmxOldRegistry tmpdir=$rmxOldTmp;
        :error ("RadiusMax: image pull/extraction failed safely: " . $rmxPullError);
    };
    /container config set registry-url=$rmxOldRegistry tmpdir=$rmxOldTmp;
    :put ("RadiusMax image downloaded and extracted: " . $rmxImageFull);
    :put "RadiusMax container created with start-on-boot enabled";

    :local rmxNewContainer [/container find where name=$rmxContainerName];
    /container start $rmxNewContainer;
    :put "RadiusMax Agent started. Existing subscriber traffic was not changed.";
    :put "RadiusMax waiting for Owner approval: the Agent is enrolling automatically and should appear as Pending.";
    :put "Persistent enrollment state must never be deleted, copied, or shared between routers.";
}
