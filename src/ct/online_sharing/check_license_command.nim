## License info query command.
##
## Replaces the C# ``CheckLicenseFunction``. Fetches the user's license
## tier from the CI platform and prints it.

import remote_config, api_client

proc checkLicenseCommand*(remoteConfig: RemoteConfig, cliToken = "",
    cliBaseUrl = "") =
  ## Queries the server for the user's license status and prints the result.
  let bearerToken = remoteConfig.getBearerToken(cliToken)
  let baseUrl = remoteConfig.resolveBaseRemoteUrl(cliBaseUrl)

  var client = initApiClient(baseUrl)
  defer: client.close()

  let info = client.getLicenseInfo(bearerToken)
  echo "License status: " & info.licenseInfo
