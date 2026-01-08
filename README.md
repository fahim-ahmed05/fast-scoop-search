# Fast Scoop Search

A tiny PowerShell helper that searches your local Scoop buckets instantly.

## Why

`scoop search` scans manifests every time. This script builds a small JSON index and only refreshes when buckets change.

## Features

- Instant lookups.
- Auto-refresh when no results.

## Requirements

- PowerShell 5.0+
- Scoop and git installed

## Usage

```powershell
.\Scoop-Search.ps1 firefox
.\Scoop-Search.ps1 extras/firefox  # bucket/name works too
```

## How it works

1) If the index is missing, it’s created on first run. 
2) If a search returns nothing, it runs `scoop update`, rescans changed buckets, and tries again.
3) Buckets are tracked by their git hash; only changed buckets are rescanned.

## Optional

```powershell
function scoop-search { & "C:\Users\Fahim\Git\fast-scoop-search\Scoop-Search.ps1" @args }
```

## Support

If you find this helpful, consider supporting.

<a href="https://www.buymeacoffee.com/fahim.ahmed" target="_blank">
  <img src="https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png" 
       alt="Buy Me A Coffee"
       style="height: 41px !important; width: 174px !important; box-shadow: 0px 3px 2px 0px rgba(190, 190, 190, 0.5);" />
</a>