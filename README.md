# mythosext

Extensions for [Mythos](https://github.com/unitreign/mythos) — a simple web novel library for KOReader. Browse, track and export your favourite stories as EPUBs to read offline.

## Adding this repo to Mythos

1. Open KOReader and launch Mythos
2. Go to **Sources**
3. Tap **Add Repo** and enter `github.com/UnitReign/mythosext`
4. Tap **Refresh Index**
5. Install any extension from the list

All available extensions are listed in [index.json](index.json).

## Writing an extension

Check the [docs](docs/) folder. 

The `extensions/novelfire.lua` file is a working reference you can read alongside the docs.

---

## Disclaimer

This repository contains only code — Lua scripts that describe how to navigate third-party websites. It does not host, store, reproduce, or distribute any written works, translations, or other copyrighted content.

Extensions in this repo access websites the same way a web browser does. Any content you read or export is fetched directly from the source website at the time of your request. We have no control over what those websites publish.

We do not endorse or encourage accessing content that you do not have the right to access. If a website requires a subscription or login to read certain chapters, those chapters will appear as locked and cannot be exported through Mythos.

If you are a content owner and believe a specific extension is being used to infringe on your rights, please open an issue and we will review it.
