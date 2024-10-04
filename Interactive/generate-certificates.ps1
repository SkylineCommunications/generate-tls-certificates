# We have to run as administrator
#Requires -RunAsAdministrator

# Class that holds RootCA paths
class RootCA {
    [string]$PathCRT
    [string]$PathKey
	[string]$Password

    RootCA([string]$rootCAcrt, [string]$rootCAkey, [string]$rootCApwd) {
        $this.PathCRT = $rootCAcrt
        $this.PathKey = $rootCAkey
		$this.Password = $rootCApwd
    }
}

# Class that holds defined configuration
class Config {

    Config() {
    }

    # Asking organization type and verify
    [string] GetOrganization() {
		$organizationInput = ""
		while ($true) {
			$organizationInput = Read-Host "Which instance are you generating certificates for? [Default: Cassandra, Options: Cassandra|Elastic|OpenSearch|NATS]"
			if($organizationInput -eq ""){
				$organizationInput = "Cassandra"
			}
			if($organizationInput -notin @("Cassandra","Elastic","OpenSearch", "NATS")){
				Write-Host -ForegroundColor red "Invalid input: Instance should be either Cassandra, Elastic, OpenSearch or NATS"
			}else{
				break
			}
    	}

        return $organizationInput
    }

    # Asking for clustername and verify
    [string] GetClusterName() {
		$clusterName = ""
        while ($true){
			$clusterName = Read-Host "Please enter the name of your cluster: [Default: DMS]"
			if ($clusterName -eq "") {
				$clusterName = "DMS"
			}
			if ($clusterName -cmatch "[^\x00-\x7F]") {
				Write-Host -ForegroundColor yellow "Warning: Your clustername contains non-ascii characters. This may prevent your nodes from starting up if you have internode encryption turned on."
				Write-Host -ForegroundColor yellow "Do you want to proceed? (May cause your cluster to fail to start) [Default: n, Options y|n]"
				$Proceed = Read-Host
				if ($Proceed -ine "y") {
					Write-Host "Quitting..."
					break
				}
			}else{
				break
			}
		}

        return $clusterName
    }

    # Asking for validity and verify
    [string] GetValidaty() {
		$validityInput = ""
		while($true){
			$validityInput = Read-Host "How long (days) should the certificates remain valid? [Default: 365 days, Min: 30, Max: 3650]"
			if($validityInput -eq ""){
				$validityInput = "365"
			}

			# Check if integer
			$validityInput = $validityInput -as [int]
			if($validityInput -eq $null){
				Write-Host -ForegroundColor red "Invalid input: Certificate validity should be an integer (days)"
			}elseif($validityInput -lt 30 -or $validityInput -gt 3650){
				Write-Host -ForegroundColor red "Invalid input: Certificate validity should be between 30 and 3650 days"
			}else{
				break
			}
		}

        return $validityInput
    }

    # Asking keysize
    [string] GetKeySize() {
		$keysizeInput = ""
		while($true){
			$keysizeInput = Read-Host "How long (bit) should the certificate key size be? [Default: 4096 bit, Options: 1024|2048|4096|8192]"
			if($keysizeInput -eq ""){
				$keysizeInput = "4096"
			}
			# check if keysize is one of the options
			if($keysizeInput -notin @("1024","2048","4096","8192")){
				Write-Host -ForegroundColor red "Invalid input: Key size should be of size 1024, 2048, 4096 or 8192 bit"
			}else{
				break
			}
		}
		
		return $keysizeInput
    }

    # Asking HostNames
    [string[]] GetHostNames() {
		$hostNames = @()

		while ($true) {
			$inputString = Read-Host "Please enter the hostnames (FQDN) of every node (space separated)"
			$hostNames = $inputString -split " " -ne ''  # Remove empty elements
			
			if ($hostNames.Count -eq 0) {
				Write-Host -ForegroundColor red "Invalid input: No hostnames were provided, please provide at least one hostname."
			} else {
				break
			}
		}

		return $hostNames
    }

    # Ask if hostnames need to be resolved
    [string] AskResolveHostName() {
        $resolveHostNameInput = Read-Host "Do you want me to try to resolve the hostnames automatically instead of manually entering the IP addresses for every node? [Default: y, Options: y|n]"
        return $resolveHostNameInput
    }
}

# Function to prompt for a valid path
function Get-ValidPath {
    param(
		[string]$defaultPath,
        [string]$file,
        [string]$tooltip
    )
    
    $path = $defaultPath
    while ($true) {
        Write-Host $tooltip
        $path = Read-Host "Please enter the absolute path to the $file"
		if(-not $path -Contains $file -or $path -eq "" -or -not (Test-Path $path -PathType Leaf)){
			 $path = Read-Host "Invalid path. Please enter the absolute path to the $file"
		}else{
			break
		}
    }

	if($path -eq ""){
		Write-Host "Invalid path to $file"
		exit 1 
	}

    return $path
}

# Function to clean up the working directory
function Clean-WorkingDirectory {
    param()
    
    $Clean = Read-Host "Do you want to remove previously generated certificates/truststores from the current directory? [Default=y, Option y|n]"
    if ($Clean -ine "n") {
        Remove-Item "*.crt_signed"
        Remove-Item "*.crt"
        Remove-Item "*.key"
        Remove-Item "*.csr"
        Remove-Item "*.cer"
        Remove-Item "*.jks"
        Remove-Item "*.conf"
        Remove-Item "*.srl"
        Remove-Item "*.p12"
		Remove-Item "*.pem"
    }
}

# Function to generate a new Root Certificate using OpenSSL tool
function Create-New-RootCA{
	param()
	
	Write-Host "Generating the root certificate"
	"[ req ]
	distinguished_name  = req_distinguished_name
	x509_extensions		= ext
	prompt              = no
	output_password     = `"$Password`"
	default_bits        = $KeySize

	[ req_distinguished_name ]
	C     = BE
	O     = $Organization
	CN    = rootCA
	OU    = `"$ClusterName`"
	
	[ ext ]
	basicConstraints = critical,CA:TRUE" | Out-File -Encoding "UTF8" rootCA.conf

	# Create a new Root CA certificate and store the private key in rootCA.key, public key in rootCA.crt
	& "$openssl" "req" "-config" "rootCA.conf" "-new" "-x509" "-nodes" "-keyout" "rootCA.key" "-out" "rootCA.crt" "-days" "$Validity"
}

# Function to generate root certificate
function Generate-RootCertificate {
    param(
        [string]$organization,
        [string]$clusterName,
        [int]$validity,
        [int]$keySize
    )

    $useExisting = Read-Host "Do you want to use an existing root certificate? [Default=y, Option y|n]"
	if ($useExisting -ine "n") {
        $rootCAcrt =  Get-ValidPath -defaultPath "C:\absolute\path\to\rootCA.crt" -file "rootCA.crt" -tooltip $null
		$rootCAkey =  Get-ValidPath -defaultPath "C:\absolute\path\to\rootCA.key" -file "rootCA.key" -tooltip $null

		$rootCApassword = ""
		while ($rootCApassword -eq "") {
			$rootCApassword = Read-Host "Please enter the password to the rootCA.key file"

			if ($rootCApassword -eq "") {
				Write-Output "Invalid password. Please enter a valid password."
			}
    	}
        return [RootCA]::new($rootCAcrt, $rootCAkey, $rootCApassword)
	}else{
		$generatedPassword = Generate-Password
		Create-New-RootCA
        return [RootCA]::new("rootCA.crt", "rootCA.key", $generatedPassword)
	}
}

# Function to verify if it's an IP Address
function IsIpAddress([string]$inputString) {
    $ipRegex = '^(\d{1,3}\.){3}\d{1,3}$'

    if ($inputString -match $ipRegex) {
        return $true
    } else {
        return $false
    }
}

# Function to resolve the HostName to IP Address
function GetIpByHostname {
    param (
        [string]$HostName
    )

	$NodeIP = ""
	# check if we need to resolve the hostname
	if($ResolveHostName -ine "n"){
		Write-Host "Resolving $i to IP..."
		try {
			$ResIp = Resolve-DnsName -Name $i -ErrorAction Stop |  Select -ExpandProperty "IpAddress" | Out-String
			$ResIp = $ResIp.Trim()
			if( ($ResIp -match '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$') -and ($ResIp -notlike '127.*') ){
				Write-Host -ForeGroundColor Green "Resolved $i to IP: $ResIp"
				$NodeIP = $ResIp
			}
			else {
				Write-Host "Could not resolve the hostname to a single IP. I found the following IPs:"
				Write-Host -ForegroundColor Green $ResIp
			}
		}
		catch {
			Write-Host -ForeGroundColor Yellow "Failed to resolve $i to a valid IP."
		}
	}

	# check if hostname was resolved
	if($NodeIP -eq ""){
		# Hostname was not resolved, ask for IP
		$NodeIP = Read-Host "Please enter the IP address for node '$i', which will be included as a SAN (Subject Alternative Name)"
		while (-not (IsIpAddress $NodeIP)){
			$NodeIP = Read-Host "Invalid IP Address. Please enter a valid IP address"
		}
	}

	return $NodeIp
}

# Function to generate node certificates
function Generate-NodeCertificates {
    param(
		[string]$organization,
        [array]$hostNames,
        [string]$resolveHostName,
        [string]$password,
        [string]$rootCAcrt,
        [string]$rootCAkey
    )

    foreach ($i in $HostNames) {
		Write-Host "Generating certificate for node: $i"
		$NodeIp = GetIpByHostname -hostname $i
			
		$inputSans = Read-Host "Please specify additional SANs (Subject Alternative Names) (space separated) [Default: None]"
		$sansArr = $inputSANs -split " " -ne ''  # Remove empty elements

		# Add SANs (Subject Alternative Names)
		$sans = [System.Text.StringBuilder]::new("san=dns:$i,ip:$nodeIp")
		$subjectAltNames = [System.Text.StringBuilder]::new("subjectAltName=DNS:$i,IP:$NodeIP")
		foreach($san in $sansArr)
		{
			if (IsIpAddress $san) {
				$sans.Append(",ip:$san")
				$subjectAltNames.Append(",IP:$san")
			} else {
				$sans.Append(",dns:$san")
				$subjectAltNames.Append(",DNS:$san")
			}
		}
		
		# Importing the public Root CA certificate in node keystore
		Write-Host "Importing Root CA certificate in node keystore"
		& "$keytool" "-keystore" "$i-node-keystore.jks" "-alias" "rootCA" "-importcert" "-file" $rootCAcrt "-keypass" "$password" "-storepass" "$password" "-noprompt"

		Write-Host "Generating new key pair for node: $i"
		& "$keytool" "-genkeypair" "-keyalg" "RSA" "-alias" "$i" "-keystore" "$i-node-keystore.jks" "-storepass" "$password" "-keypass" "$password" "-validity" "$Validity" "-keysize" "$KeySize" "-dname" "CN=$i, OU=$ClusterName, O=$Organization, C=BE" "-ext" "$($sans.ToString())"

		Write-Host "Creating signing request"
		& "$keytool" "-keystore" "$i-node-keystore.jks" "-alias" "$i" "-certreq" "-file" "$i.csr" "-keypass" "$password" "-storepass" "$password" 

		# Add both hostname and IP as subject alternative name, write this configuration to a temp file
		"$($subjectAltNames)" | Out-File -Encoding "UTF8" "${i}.conf"

		# Sign the node certificate with the private key of the rootCA
		Write-Host "Signing certificate with Root CA certificate"
		& "$openssl" "x509" "-req" "-CA" $rootCAcrt "-CAkey" $rootCAkey "-in" "$i.csr" "-out" "$i.crt_signed" "-days" "$Validity" "-CAcreateserial" "-passin" "pass:$password" "-extfile" "$i.conf"

		# Import the signed certificate in the node key store
		Write-Host "Importing signed certificate for $i in node keystore"
		& "$keytool" "-keystore" "$i-node-keystore.jks" "-alias" "$i" "-importcert" "-file" "$i.crt_signed" "-keypass" "$password" "-storepass" "$password" "-noprompt"

		# Export the public key for every node
		Write-Host "Exporting public key for $i"
		& "$keytool" "-exportcert" "-alias" "$i" "-keystore" "$i-node-keystore.jks" "-file" "$i-public-key.cer" "-storepass" "$password"

		# Debugging: Log the certificates for this node
		#Write-Host "Certificates in node-keystore for $i:"
		#& "$keytool -list -keystore $i-node-keystore.jks -storepass $Password"

		# Debugging: Create keystore with public cert (mostly for CQL clients DevCenter)
		# Write-Host "Creating public truststore for clients"
		# & "$keytool" "-keystore" "$i-public-truststore.jks" "-alias" "$i" "-importcert" "-file" "$i-public-key.cer" "-keypass" "$Password" "-storepass" "$Password" "-noprompt"
		
		# Convert to PKCS#12, usable for ElasticSearch/OpenSearch
		Write-Host "Creating PKCS#12 from JKS for $i"
		& "$keytool" "-importkeystore" "-srckeystore" "$i-node-keystore.jks" "-destkeystore" "$i-node-keystore.p12" "-srcstoretype" "JKS" "-deststoretype" "PKCS12" "-srcstorepass" "$password" "-deststorepass" "$password"
		
		# Generating certificate.pem file in case of NATS
		if ($organization -eq "NATS") {							
			Write-Host "Generating PEM files"
			& "$openssl" "pkcs12" "-in" "$i-node-keystore.p12" "-out" "$i-certificate.pem" "-clcerts" "-nokeys" "-passin" "pass:$password"
			& "$openssl" "pkcs12" "-in" "$i-node-keystore.p12" "-out" "$i-key.pem" "-nocerts" "-nodes" "-passin" "pass:$password"

			# Read the content of the files
			$certFileContent = Get-Content -Path "$i-certificate.pem" -Raw
			$keyFileContent = Get-Content -Path "$i-key.pem" -Raw

			# Use regular expression to remove the "Bag Attributes" section
			$cleanedCertFileContent = $certFileContent -replace '(?s)Bag Attributes.*?-----BEGIN CERTIFICATE-----', '-----BEGIN CERTIFICATE-----'
			$cleanedKeyFileContent = $keyFileContent -replace '(?s)Bag Attributes.*?-----BEGIN PRIVATE KEY-----', '-----BEGIN PRIVATE KEY-----'

			# Write the cleaned content back to the files
			$cleanedCertFileContent | Set-Content -Path "$i-certificate.pem"
			$cleanedKeyFileContent | Set-Content -Path "$i-key.pem"

			# Remove .p12 file
			Remove-Item "*.p12"
		}

		Write-Host "Finished for $i"
	}
}

# Function to generate an Admin certificate (only required for OpenSearch)
function Generate-Admin-Certificate{
	param(
        [string]$password,
        [string]$rootCAcrt,
        [string]$rootCAkey
    )
	Write-Host "Generating the Admin certificate"
	"[ req ]
	distinguished_name  = req_distinguished_name
	prompt              = no
	output_password     = `"$Password`"
	default_bits        = $KeySize

	[ req_distinguished_name ]
	C     = BE
	O     = $Organization
	CN    = Admin
	OU    = `"$ClusterName`"" | Out-File -Encoding "UTF8" Admin.conf


	# generate new keypair
	& "$openssl" "genrsa" "-out" "admin_key.tmp" "$keysize"

	# convert to PKCS8 format
	& "$openssl" "pkcs8" "-inform" "PEM" "-in" "admin_key.tmp" "-topk8" "-nocrypt" "-v1" "PBE-SHA1-3DES" "-out" "admin-key.pem"

	# generate signing request
	& "$openssl" "req" "-new" "-key" "admin-key.pem" "-out" "admin.csr" "-config" "Admin.conf"

	# sign the cert with the RootCA
	& "$openssl" "x509" "-req" "-CA" $rootCAcrt "-CAkey" $rootCAkey "-in" "admin.csr" "-out" "admin.pem" "-days" "$Validity" "-CAcreateserial" "-passin" "pass:$password"
}

# Function to add public keys to keystore of every other node
function Add-PublicKeysToKeystore {
    param(
        [array]$hostNames,
        [string]$password
    )

    if ($HostNames.Length -ge 2) {
        Write-Host "Adding the public key of every node to every other node..."
        foreach ($i in $HostNames) {
            foreach ($j in $HostNames) {
                if ($i -ceq $j) {
                    continue
                }

                & "$keytool" "-keystore" "$i-node-keystore.p12" "-alias" "$j" "-importcert" "-file" "$j-public-key.cer" "-keypass" "$Password" "-storepass" "$Password" "-noprompt"
            }
        }
    }
}

# Function to clean up and provide final instructions
function Clean-Up-And-Instructions {
    param(
        [string]$password,
        [string]$rootCAcrt,
        [string]$rootCAkey
    )

	Remove-Item "*.crt_signed"
	Remove-Item "*.csr"
	Remove-Item "*.conf"
	Remove-Item "*.srl"
	Remove-Item "*.tmp"
	# Remove line below for debugging with devcenter
	Remove-Item "*.jks"

	Write-Host 
	Write-Host -ForegroundColor Green "Please make sure the $rootCAcrt is trusted on every client"
	
	Write-Host
	Write-Host -ForeGroundColor Green "Copy the following keystores to the matching node:"
	Get-ChildItem -File "*-node-keystore.p12" | foreach-object { Write-Host "> $_"}

	Write-Host
	Write-Host -ForeGroundColor Green "Keep the following files PRIVATE:"
	Get-ChildItem -File $rootCAkey | foreach-object { Write-Host "> $_"}
}

# Function to log the configuration details
function Log-ConfigurationDetails {
    param(
        [string]$organization,
        [string]$clusterNames,
        [string]$hostNames,
        [string]$validity,
        [string]$keysize,
        [string]$resolveHostName
    )

    Write-Host "---- Generating Node(s) Certificates ----"
    Write-Host "Organization type: $Organization"
    Write-Host "Cluster name: $ClusterNames"
    Write-Host "Host names: $HostNames"
    Write-Host "Validity: $Validity"
    Write-Host "Keysize: $Keysize"
    Write-Host "Resolve hostnames? $ResolveHostName"
}

# Function to generate secure certificate password
function Generate-Password {
    $Password = $null
    
    $GeneratePassword = Read-Host "Do you want me to automatically generate a secure certificate password (instead of manually entering one)? [Default: y, Options: y|n]"
	if($GeneratePassword -ine "n"){
		$Password = & "$openssl" "rand" "-hex" "20"
		Write-Host -ForegroundColor Green "Generated password is: $Password"
	}
	else {
		$Password = Read-Host "Please enter a password for the certificates and truststores [Min length: 10]"
		$Confirmation = Read-Host "Please re-enter the password"
		While($Password -cne $Confirmation -or $Password.Length -lt 10){
			Write-Host "The passwords did not match or it is shorter then 10 characters"
			$Password = Read-Host "Please enter a password for the certificates and truststores"
			$Confirmation = Read-Host "Please re-enter the password"
		}
	}

    return $Password
}

# Main Function
function Main{
    # Get executables phase
	$keytool = Get-ValidPath -defaultPath "C:\absolute\path\to\keytool.exe" -file "keytool.exe" -tooltip "It is recommended to use the keytool executable provided with cassandra/elastic/opensearch."
	$openssl = Get-ValidPath -defaultPath "C:\absolute\path\to\openssl.exe" -file "openssl.exe" -tooltip $null

    # Cleanup phase
	Write-Host
	Clean-WorkingDirectory

	# Configuration phase
	Write-Host "Starting Cassandra/Elastic/OpenSearch/NATS TLS encryption configuration..."
    $config = [Config]::new()
    $Organization = $config.GetOrganization()
    $ClusterName = $config.GetClusterName()
    $Hostnames = $config.GetHostNames()
    $Validity = $config.GetValidaty()
    $Keysize = $config.GetKeySize()
    $ResolveHostName = $config.AskResolveHostName()

    # Certificates phase
    Log-ConfigurationDetails -organization $Organization -clusterNames $ClusterName -hostNames $Hostnames -validity $Validity -keysize $Keysize -resolveHostName $ResolveHostName
	$rootCA = Generate-RootCertificate -organization $Organization -clusterName $ClusterName -validity $Validity -keySize $Keysize
	Generate-NodeCertificates -organization $Organization -hostNames $HostNames -resolveHostName $ResolveHostName -password $rootCA.Password -rootCAcrt $rootCA.PathCRT -rootCAkey $rootCA.PathKey
	Add-PublicKeysToKeystore -hostNames $HostNames -password $rootCA.Password

	if($Organization -eq "OpenSearch"){
		Generate-Admin-Certificate -password $rootCA.Password -rootCAcrt $rootCA.PathCRT -rootCAkey $rootCA.PathKey
	}

	Clean-Up-And-Instructions -password $rootCA.Password -rootCAcrt $rootCA.PathCRT -rootCAkey $rootCA.PathKey
}

Main
Write-Host "Script complete"
exit 0