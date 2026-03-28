## Tenant resolution: maps organization slug or UUID to a tenant GUID.
##
## Replaces the C# ``TenantResolver``. Resolution logic:
## 1. If the input is a valid GUID, return it directly.
## 2. Fetch all tenants and match by slug (case-insensitive).
## 3. If no org specified and exactly one tenant exists, auto-select it.
## 4. If multiple tenants are available and none specified, raise with a
##    listing of available slugs.

import std/[strutils, sequtils, strformat]
import api_client

proc isGuid(s: string): bool =
  ## Checks if ``s`` looks like a valid UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx).
  if s.len != 36:
    return false
  for i, c in s:
    if i in {8, 13, 18, 23}:
      if c != '-': return false
    else:
      if c notin HexDigits: return false
  return true

proc resolveTenantValueOrSlug*(defaultOrgSlug, cliOrgSlug: string): string =
  ## Returns the CLI-provided org if non-empty, else the stored default.
  if cliOrgSlug.len > 0: cliOrgSlug
  else: defaultOrgSlug

proc resolveTenantId*(client: ApiClient, orgSlug: string,
    bearerToken: string): tuple[tenantId: string, orgSlug: string] =
  ## Resolves an organization slug (or UUID) to a (tenantId, slug) tuple.
  ##
  ## - If ``orgSlug`` is a valid GUID, returns it directly with the slug unchanged.
  ## - If ``orgSlug`` is non-empty, fetches tenants and matches by slug.
  ## - If ``orgSlug`` is empty, fetches tenants and auto-selects if exactly one.
  ## - Raises ``ValueError`` if the tenant cannot be resolved.

  # Direct GUID input — skip the API call.
  if orgSlug.isGuid():
    return (tenantId: orgSlug, orgSlug: orgSlug)

  let tenants = client.getTenants(bearerToken)

  if orgSlug.len > 0:
    # Match by slug (case-insensitive).
    for t in tenants:
      if t.slug.cmpIgnoreCase(orgSlug) == 0:
        return (tenantId: t.tenantId, orgSlug: t.slug)
    raise newException(ValueError,
      fmt"Organization '{orgSlug}' not found. " &
      "Available: " & tenants.mapIt(it.slug).join(", "))

  # No org specified — auto-select if exactly one tenant.
  if tenants.len == 0:
    raise newException(ValueError, "No tenants available for the user.")
  if tenants.len == 1:
    return (tenantId: tenants[0].tenantId, orgSlug: tenants[0].slug)

  raise newException(ValueError,
    "Multiple tenants available for the user. " &
    "Please specify one with --org: " &
    tenants.mapIt(it.slug).join(", "))
