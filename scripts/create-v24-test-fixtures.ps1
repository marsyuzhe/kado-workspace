$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'artifacts\qa\v24-tls'
if(Test-Path -LiteralPath $out){throw 'TLS fixture already exists; keep previous evidence.'}
New-Item -ItemType Directory -Path $out | Out-Null
# Synthetic localhost certificate only. No access to Windows certificate stores,
# user certificates, live credentials or platform signing material.
$rsa=[Security.Cryptography.RSA]::Create(2048)
try {
 $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=localhost',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
 $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
 $san.AddDnsName('localhost');$san.AddIpAddress([Net.IPAddress]::Loopback)
 $request.CertificateExtensions.Add($san.Build())
 $cert=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1),[DateTimeOffset]::UtcNow.AddDays(7))
 try {
  [IO.File]::WriteAllText((Join-Path $out 'cert.pem'),[Security.Cryptography.PemEncoding]::WriteString('CERTIFICATE',$cert.RawData))
  [IO.File]::WriteAllText((Join-Path $out 'key.pem'),[Security.Cryptography.PemEncoding]::WriteString('PRIVATE KEY',$rsa.ExportPkcs8PrivateKey()))
 } finally {$cert.Dispose()}
} finally {$rsa.Dispose()}
Write-Output 'Owned localhost TLS fixture created; not a trusted certificate.'
