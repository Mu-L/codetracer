## License activation command: downloads a signed CTL license blob and
## saves it to ``~/.config/codetracer/license.dat``.
##
## Replaces the C# ``ActivateFunction``. The CTL format is:
## - 4 bytes: magic ``CTL\x01``
## - 4 bytes: payload length (little-endian u32)
## - N bytes: JSON payload
## - 64 bytes: Ed25519 signature
##
## Minimum valid size is 74 bytes (4 + 4 + 2 + 64).
## The Nim side does NOT verify the signature — that's done by ct-native-replay
## (Rust) at replay time.

import std/[os, strformat]
import remote_config, api_client

const
  LicenseDatFileName = "license.dat"
  MinLicenseSize = 74

proc activateCommand*(remoteConfig: RemoteConfig, cliToken = "",
    cliBaseUrl = "") =
  ## Downloads a signed license from the server and saves it locally.
  ## Exits with code 1 on any error (missing token, network failure, etc.).
  try:
    let bearerToken = remoteConfig.getBearerToken(cliToken)
    let baseUrl = remoteConfig.resolveBaseRemoteUrl(cliBaseUrl)

    echo "Activating license..."
    var client = initApiClient(baseUrl)
    defer: client.close()

    let licenseBlob = client.issueLicense(bearerToken)

    if licenseBlob.len < MinLicenseSize:
      raise newException(ValueError,
        fmt"Server returned an invalid license file ({licenseBlob.len} bytes, " &
        fmt"expected at least {MinLicenseSize}).")

    # Save to the same directory as the config file.
    let licensePath = remoteConfig.configDir() / LicenseDatFileName
    let dir = parentDir(licensePath)
    if not dirExists(dir):
      createDir(dir)

    writeFile(licensePath, licenseBlob)
    echo fmt"License activated successfully."
    echo fmt"  Saved to: {licensePath}"
    echo fmt"  Size: {licenseBlob.len} bytes"
  except CatchableError as e:
    echo "error: " & e.msg
    quit(1)
