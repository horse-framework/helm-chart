param(
    [string]$HelmPath = 'helm',
    [string]$KubectlPath = 'kubectl'
)

$ErrorActionPreference = 'Stop'
$chartPath = Split-Path $PSScriptRoot -Parent
$valuesFile = [System.IO.Path]::GetTempFileName()
$script:checks = 0

function Assert-That($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Render([hashtable]$Values = @{}) {
    # Synthetic credentials only; no cluster connection is made.
    $Values | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $valuesFile -Encoding utf8
    $yaml = & $HelmPath template review $chartPath --namespace render-test -f $valuesFile `
        --set-string jockey.username=example --set-string cluster.sharedSecret=render-only
    if ($LASTEXITCODE -ne 0) { throw 'helm template failed' }
    # kubectl's local unstructured parser preserves YAML scalar types.
    # This validates relationships and types below, not the full Kubernetes schema.
    $json = $yaml | & $KubectlPath label --local --dry-run=client --overwrite -f - render-test=true -o json
    if ($LASTEXITCODE -ne 0) { throw 'Local YAML decoding failed' }
    # kubectl emits one pretty-printed JSON object per YAML document.
    $objects = ($json -join "`n") -replace '(?m)^\}\r?\n\{', '},{'
    return (('[' + $objects + ']') | ConvertFrom-Json)
}

function Find-Resource($Resources, [string]$Kind, [string]$Name = '') {
    $Resources | Where-Object { $_.kind -eq $Kind -and (-not $Name -or $_.metadata.name -eq $Name) }
}

function Assert-Rejected([hashtable]$Values, [string]$ErrorPattern, [string]$Command = 'template') {
    $Values | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $valuesFile -Encoding utf8
    $arguments = @('template', 'review', $chartPath, '-f', $valuesFile)
    if ($Command -eq 'lint') { $arguments = @('lint', $chartPath, '--strict', '-f', $valuesFile) }
    # Expected native failures are captured so assertions can check their cause.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $output = & $HelmPath @arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    Assert-That ($exitCode -ne 0) "$Command accepted invalid input: $ErrorPattern"
    Assert-That ($output -match $ErrorPattern) "$Command failed for an unexpected reason: $output"
}

function Assert-PortLinks($Resources) {
    $pod = (Find-Resource $Resources StatefulSet).spec.template.spec.containers[0]
    $services = @(Find-Resource $Resources Service)
    foreach ($service in $services) {
        foreach ($port in $service.spec.ports) {
            $target = @($pod.ports | Where-Object name -eq $port.targetPort)
            Assert-That ($target.Count -eq 1) "Missing container target for $($service.metadata.name)/$($port.name)"
        }
    }
    foreach ($ingress in (Find-Resource $Resources Ingress)) {
        foreach ($rule in $ingress.spec.rules) {
            foreach ($path in $rule.http.paths) {
                $backend = $path.backend.service
                $service = Find-Resource $Resources Service $backend.name
                Assert-That ($null -ne $service) 'Missing backend Service'
                Assert-That ($service.metadata.namespace -eq $ingress.metadata.namespace) 'Cross-namespace backend'
                Assert-That (@($service.spec.ports | Where-Object name -eq $backend.port.name).Count -eq 1) 'Missing Ingress backend port'
                Assert-That ($backend.port.name -ne 'horse-node') 'Node traffic must not have an Ingress'
            }
        }
    }
}

try {
    & $HelmPath lint $chartPath --strict
    if ($LASTEXITCODE -ne 0) { throw 'helm lint failed' }

    $base = Render @{ jockey = @{ password = 'render-only' } }
    Assert-That (@($base | Where-Object { $_.metadata.namespace -ne 'render-test' }).Count -eq 0) 'Release namespace mismatch'
    Assert-PortLinks $base
    $stateful = Find-Resource $base StatefulSet
    Assert-That ($stateful.spec.updateStrategy.type -eq 'RollingUpdate') 'Default update strategy'
    $container = $stateful.spec.template.spec.containers[0]
    Assert-That ((Find-Resource $base ConfigMap).data.HORSE_DATA_PATH -ceq '/etc/horse/data') 'Default persistent data location changed'
    foreach ($pathCase in @(
        @{ mount = '/var/lib/horse'; data = ''; expectedMount = '/var/lib/horse'; expectedData = '/var/lib/horse/data' },
        @{ mount = '/var/lib/horse/'; data = ''; expectedMount = '/var/lib/horse'; expectedData = '/var/lib/horse/data' },
        @{ mount = '/var/lib/horse'; data = '/var/lib/horse/queues'; expectedMount = '/var/lib/horse'; expectedData = '/var/lib/horse/queues' },
        @{ mount = '/var/lib/horse'; data = '/var/lib/horse'; expectedMount = '/var/lib/horse'; expectedData = '/var/lib/horse' },
        @{ mount = '/var/lib/horse/./'; data = '/var/lib/horse/data/../queues'; expectedMount = '/var/lib/horse'; expectedData = '/var/lib/horse/queues' },
        @{ mount = '/'; data = ''; expectedMount = '/'; expectedData = '/data' }
    )) {
        $pathResources = Render @{ mount = @{ path = $pathCase.mount }; server = @{ dataPath = $pathCase.data } }
        $mountPath = (Find-Resource $pathResources StatefulSet).spec.template.spec.containers[0].volumeMounts[0].mountPath
        $dataPath = (Find-Resource $pathResources ConfigMap).data.HORSE_DATA_PATH
        Assert-That ($mountPath -ceq $pathCase.expectedMount) 'PVC mount path was not normalized'
        Assert-That ($dataPath -ceq $pathCase.expectedData) 'Data path is not derived from or contained in PVC mount'
    }
    foreach ($invalidDataPath in @('/tmp/data', '/etc/horse-backup/data', '/etc/horse/../data')) {
        # Helm 3 lint intentionally logs template fail() calls without failing.
        # Cross-field containment must therefore also be tested with template.
        Assert-Rejected @{ server = @{ dataPath = $invalidDataPath }; deployment = @{ restartOnConfigChange = $false } } 'server.dataPath must be within mount.path'
    }
    $invalidValues = @(
        @{ values = @{ cluster = @{ replica = 2.5 } }; field = 'cluster.replica' },
        @{ values = @{ cluster = @{ replica = -1 } }; field = 'cluster.replica' },
        @{ values = @{ server = @{ port = 70000 } }; field = 'server.port' },
        @{ values = @{ server = @{ port = 0 } }; field = 'server.port' },
        @{ values = @{ server = @{ websocketPort = -1 } }; field = 'server.websocketPort' },
        @{ values = @{ server = @{ websocketPort = 65536 } }; field = 'server.websocketPort' },
        @{ values = @{ jockey = @{ port = '2627' } }; field = 'jockey.port' },
        @{ values = @{ cluster = @{ clusterType = 'unknown' } }; field = 'cluster.clusterType' },
        @{ values = @{ queue = @{ putback = 'unknown' } }; field = 'queue.putback' },
        @{ values = @{ queue = @{ ackTimeout = -1 } }; field = 'queue.ackTimeout' },
        @{ values = @{ deployment = @{ rollingUpdate = 'false' } }; field = 'deployment.rollingUpdate' },
        @{ values = @{ deployment = @{ resources = @{ limits = @{ cpu = 'unlimited' } } } }; field = 'deployment.resources.limits.cpu' },
        @{ values = @{ deployment = @{ resources = @{ limits = @{ memory = '-1Gi' } } } }; field = 'deployment.resources.limits.memory' },
        @{ values = @{ mount = @{ path = 'relative/path' } }; field = 'mount.path' },
        @{ values = @{ mount = @{ storage = 'unlimited' } }; field = 'mount.storage' },
        @{ values = @{ server = @{ dataPath = 'relative/data' } }; field = 'server.dataPath' },
        @{ values = @{ image = @{ pullPolicy = 'Sometimes' } }; field = 'image.pullPolicy' }
    )
    foreach ($invalid in $invalidValues) {
        foreach ($command in @('lint', 'template')) {
            Assert-Rejected $invalid.values ([regex]::Escape($invalid.field)) $command
        }
    }
    $boundary = Render @{
        cluster = @{ replica = 0 }
        server = @{ port = 65535; websocketPort = 0 }
        deployment = @{ resources = @{ requests = @{ cpu = 0.5; memory = '1e9' }; limits = @{ 'nvidia.com/gpu' = 1 } } }
    }
    Assert-That ((Find-Resource $boundary StatefulSet).spec.replicas -eq 0) 'Scale-to-zero must remain valid'
    Assert-That (((Find-Resource $boundary Service review).spec.ports | Where-Object name -eq horse-messaging).port -eq 65535) 'Highest valid Service port rejected'
    Assert-That ($container.image -eq 'horseframework/messaging-server:8.3.0') 'Image must be versioned'
    Assert-That (($container.ports.containerPort | Sort-Object) -join ',' -eq '2626,2627,2628,2680') 'Fixed listeners'
    Assert-That ($null -eq $container.readinessProbe) 'Readiness must remain unchanged'
    Assert-That (@($container.resources.requests.PSObject.Properties).Count -eq 0) 'Default CPU/memory requests must be empty'
    Assert-That (@($container.resources.limits.PSObject.Properties).Count -eq 0) 'Default CPU/memory limits must be empty'
    $resourceSettings = @{
        requests = @{ cpu = '100m'; memory = '128Mi' }
        limits = @{ cpu = '500m'; memory = '512Mi' }
    }
    $sized = Find-Resource (Render @{ deployment = @{ resources = $resourceSettings } }) StatefulSet
    $actualResources = $sized.spec.template.spec.containers[0].resources
    foreach ($category in @('requests', 'limits')) {
        foreach ($resource in @('cpu', 'memory')) {
            Assert-That ($actualResources.$category.$resource -ceq $resourceSettings[$category][$resource]) "Container $category.$resource not applied"
        }
    }
    Assert-That (($sized.spec.template | ConvertTo-Json -Depth 20) -cne ($stateful.spec.template | ConvertTo-Json -Depth 20)) 'Resource changes must update the Pod template'
    $memoryOnly = Find-Resource (Render @{ deployment = @{ resources = @{ limits = @{ memory = '1Gi' } } } }) StatefulSet
    Assert-That ($memoryOnly.spec.template.spec.containers[0].resources.limits.memory -ceq '1Gi') 'Memory-only limit not applied'
    Assert-That ($null -eq $memoryOnly.spec.template.spec.containers[0].resources.limits.cpu) 'Unrequested CPU limit was added'

    $custom = Render @{
        deployment = @{ namespace = 'custom'; rollingUpdate = $false }
        cluster = @{ replica = 3 }
        server = @{ port = 3000; websocketPort = 8081 }
        jockey = @{ port = 8080; password = 'render-only' }
        websocket = @{ ingressHost = '.ws.example.com' }
    }
    Assert-That (@($custom | Where-Object { $_.metadata.namespace -ne 'custom' }).Count -eq 0) 'Explicit namespace mismatch'
    Assert-PortLinks $custom
    $customStateful = Find-Resource $custom StatefulSet
    Assert-That ($customStateful.spec.updateStrategy.type -eq 'OnDelete') 'OnDelete missing'
    Assert-That ($null -eq $customStateful.spec.updateStrategy.rollingUpdate) 'Unexpected rollingUpdate settings'
    Assert-That (@(Find-Resource $custom Service).Count -eq 5) 'Shared, headless or per-pod Services missing'
    $shared = Find-Resource $custom Service review
    Assert-That (($shared.spec.ports | Where-Object name -eq horse-messaging).port -eq 3000) 'Custom client Service port'
    Assert-That (@($shared.spec.ports | Where-Object name -eq horse-node).Count -eq 0) 'Node port on shared Service'
    foreach ($service in (Find-Resource $custom Service | Where-Object { $_.metadata.name -ne 'review' })) {
        Assert-That (($service.spec.ports | Where-Object name -eq horse-messaging).port -eq 2626) 'Peer discovery port changed'
        Assert-That (($service.spec.ports | Where-Object name -eq horse-node).port -eq 2628) 'Node port missing'
    }
    Assert-That ((Find-Resource $custom Ingress review-ingress).spec.rules[0].host -eq 'review.ws.example.com') 'Independent WebSocket host'

    # Resolve the downward-API/environment inputs using the application's actual
    # identity rule: replacing INDEX must match HOSTNAME for exactly one node.
    foreach ($case in @(
        @{ replicas = 1; namespace = 'render-test'; domain = 'cluster.local'; override = '' },
        @{ replicas = 3; namespace = 'render-test'; domain = 'cluster.local'; override = '' },
        @{ replicas = 5; namespace = 'render-test'; domain = 'cluster.local'; override = '' },
        @{ replicas = 3; namespace = 'custom'; domain = 'corp.internal'; override = 'custom' }
    )) {
        $dnsResources = Render @{
            cluster = @{ replica = $case.replicas; dnsDomain = $case.domain }
            deployment = @{ namespace = $case.override }
        }
        $dnsStateful = Find-Resource $dnsResources StatefulSet
        Assert-That ($dnsStateful.spec.replicas -eq $case.replicas) 'StatefulSet replica count mismatch'
        $headless = Find-Resource $dnsResources Service $dnsStateful.spec.serviceName
        Assert-That ($headless.metadata.name -eq 'review-headless') 'StatefulSet governing Service mismatch'
        Assert-That ($headless.spec.clusterIP -ceq 'None') 'Governing Service must be headless'
        Assert-That ($headless.spec.publishNotReadyAddresses -eq $true) 'Bootstrap DNS requires unready addresses'
        Assert-That ($headless.spec.selector.app -eq $dnsStateful.spec.template.metadata.labels.app) 'Headless selector mismatch'
        Assert-That ($headless.metadata.namespace -eq $case.namespace) 'Headless namespace mismatch'
        Assert-That (($headless.spec.ports.port | Sort-Object) -join ',' -eq '2626,2628') 'Headless internal ports'
        $environment = $dnsStateful.spec.template.spec.containers[0].env
        $names = @($environment.name)
        Assert-That (($environment | Where-Object name -eq HORSE_POD_NAME).valueFrom.fieldRef.fieldPath -eq 'metadata.name') 'Pod name must come from downward API'
        Assert-That ([array]::IndexOf($names, 'HORSE_POD_NAME') -lt [array]::IndexOf($names, 'HOSTNAME')) 'Dependent environment order'
        $selfTemplate = ($environment | Where-Object name -eq HOSTNAME).value
        $peerTemplate = ($environment | Where-Object name -eq HORSE_HOSTNAME).value
        if ($case.replicas -gt 1) {
            Assert-That ([int]($environment | Where-Object name -eq HORSE_HOST_COUNT).value -eq $case.replicas) 'Horse peer count differs from StatefulSet replicas'
            Assert-That (($environment | Where-Object name -eq HORSE_HOST_START_INDEX).value -ceq '0') 'Peer ordinals must start at zero'
        }
        for ($ordinal = 0; $ordinal -lt $case.replicas; $ordinal++) {
            $podName = "review-$ordinal"
            $expectedDns = "$podName.review-headless.$($case.namespace).svc.$($case.domain)"
            $selfDns = $selfTemplate.Replace('$(HORSE_POD_NAME)', $podName)
            Assert-That ($selfDns -ceq $expectedDns) 'Self hostname is not the StatefulSet Pod DNS record'
            if ($case.replicas -gt 1) {
                $peerDns = @(0..($case.replicas - 1) | ForEach-Object { $peerTemplate.Replace('INDEX', [string]$_) })
                Assert-That (@($peerDns | Where-Object { $_ -eq $selfDns }).Count -eq 1) 'Horse must recognize itself exactly once'
                Assert-That (@($peerDns | Where-Object { $_ -ne $selfDns }).Count -eq ($case.replicas - 1)) 'Incorrect peer count after self-exclusion'
                Assert-That ($peerDns[$ordinal] -ceq $expectedDns) 'Peer template DNS mismatch'
            }
        }
        Assert-That ((Find-Resource $dnsResources Service review).spec.type -eq 'ClusterIP') 'Shared client Service must remain'
        Assert-That (@(Find-Resource $dnsResources Ingress | Where-Object {
            $_.spec.rules[0].http.paths[0].backend.service.name -eq $headless.metadata.name
        }).Count -eq 0) 'Ingress must not target the discovery Service'
        Assert-PortLinks $dnsResources
    }

    foreach ($jockeyIngress in @($true, $false)) {
        foreach ($wsIngress in @($true, $false)) {
            $resources = Render @{ jockey = @{ ingress = $jockeyIngress }; websocket = @{ ingress = $wsIngress } }
            $ingresses = @(Find-Resource $resources Ingress)
            $expected = 2 * ([int]$jockeyIngress + [int]$wsIngress)
            Assert-That ($ingresses.Count -eq $expected) 'Ingress switches are coupled'
            Assert-That (@($ingresses | Where-Object { $_.metadata.name -like '*jockey*' }).Count -eq (2 * [int]$jockeyIngress)) 'Jockey switch'
            Assert-PortLinks $resources
        }
    }
    $disabled = Render @{ jockey = @{ enabled = $false }; server = @{ websocketPort = 0 } }
    Assert-That (@(Find-Resource $disabled Ingress).Count -eq 0) 'Disabled listeners have Ingresses'
    Assert-That ((Find-Resource $disabled ConfigMap).data.HORSE_OVER_WEBSOCKETS -ceq '0') 'WebSocket listener not disabled'
    Assert-That (@((Find-Resource $disabled StatefulSet).spec.template.spec.containers[0].ports).Count -eq 2) 'Disabled container ports remain'
    Assert-PortLinks $disabled

    foreach ($password in @('123456', 'demo: pass', "quote`" and newline`nnext line")) {
        $strings = Render @{ queue = @{ putback = 'No' }; jockey = @{ password = $password } }
        $secret = Find-Resource $strings Secret
        $config = Find-Resource $strings ConfigMap
        Assert-That ($secret.stringData.HORSE_JOCKEY_PASSWORD -is [string]) 'Password scalar type'
        Assert-That ($secret.stringData.HORSE_JOCKEY_PASSWORD -ceq $password) 'Password round-trip'
        Assert-That ($config.data.HORSE_QUEUE_PUTBACK -ceq 'No') 'No converted to boolean'
        foreach ($property in $config.data.PSObject.Properties) {
            Assert-That ($property.Value -is [string]) "ConfigMap field $($property.Name) is not a string"
        }
    }

    $annotations = $stateful.spec.template.metadata.annotations
    $same = (Find-Resource (Render @{ jockey = @{ password = 'render-only' } }) StatefulSet).spec.template.metadata.annotations
    Assert-That ($same.'checksum/config' -eq $annotations.'checksum/config') 'Nondeterministic config checksum'
    Assert-That ($same.'checksum/secret' -eq $annotations.'checksum/secret') 'Nondeterministic secret checksum'
    $changedConfig = (Find-Resource (Render @{ queue = @{ messageLimit = 100 }; jockey = @{ password = 'render-only' } }) StatefulSet).spec.template.metadata.annotations
    Assert-That ($changedConfig.'checksum/config' -ne $annotations.'checksum/config') 'Config change not detected'
    Assert-That ($changedConfig.'checksum/secret' -eq $annotations.'checksum/secret') 'Config change affected secret checksum'
    $changedSecret = (Find-Resource (Render @{ jockey = @{ password = 'changed' } }) StatefulSet).spec.template.metadata.annotations
    Assert-That ($changedSecret.'checksum/secret' -ne $annotations.'checksum/secret') 'Secret change not detected'
    Assert-That ($changedSecret.'checksum/config' -eq $annotations.'checksum/config') 'Secret change affected config checksum'
    $optOut = Find-Resource (Render @{ deployment = @{ restartOnConfigChange = $false } }) StatefulSet
    Assert-That ($null -eq $optOut.spec.template.metadata.annotations) 'Checksum opt-out failed'
    $digest = 'sha256:' + ('a' * 64)
    $pinned = Find-Resource (Render @{ image = @{ digest = $digest } }) StatefulSet
    Assert-That ($pinned.spec.template.spec.containers[0].image -eq "horseframework/messaging-server@$digest") 'Digest precedence failed'
    Write-Output "Passed $script:checks render assertions; no cluster access."
}
finally {
    Remove-Item -LiteralPath $valuesFile -Force
}
