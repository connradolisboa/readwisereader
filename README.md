# A KOReader plugin for Readwise and Readwise Reader
A plugin for KOReader integration with the highlight saving and read later services Readwise and Readwise Reader. A Readwise subscription is required. 

## Key features:
- Articles in Readwise Reader saved to “Inbox”, “Later” or “Shortlist” are downloaded to KOReader as HTML files.
- Images are downloaded where this is possible.
- Articles which have been read in KOReader and marked as “finished” will be moved to the Readwise Reader Archive at the next sync, and deleted from KOReader.
- At sync, articles which have been archived in Readwise Reader will be deleted from KOReader.
- Particular types of article, locations and document tags can be excluded from syncing in the settings menu.
- Optionally, the plugin will only sync articles tagged as 'koreader' in Readwise (off by default).
- The number of articles downloaded per sync can be limited in the settings menu (default: unlimited).
- Highlights and notes that are saved in KOReader are exported to Readwise in the same sync process (disabled by default - enable in the settings menu). 
- A local book can be explicitly linked to one Reader book without downloading Reader HTML. Its highlights then export with that Reader book's saved metadata; the plugin never links books from a filename or title alone.
- Downloads show a progress bar with how many articles are done, how many are left, how much has been downloaded so far, and a Cancel button. Cancelling keeps everything already downloaded and takes effect at the next article, so a large article with many images finishes fetching first.
- Optionally, an article you have read further in Readwise Reader on another device will open at roughly that place in KOReader ("Start at Readwise Reader position", off by default). The position is approximate, and it only travels from Readwise Reader to KOReader - see Limitations below.
- Very image heavy files will download, but may cause KOReader to crash if the file is very large and your ereader can’t cope with this. Due to the way images are saved and the limitations of HTML files, this is more of an issue than with EPUBs. To mitigate this, there is a setting to allow the user to cap the size of a file, after which further images are not downloaded. This is set to 10MB by default, but may be changed according to the limits of the user’s setup. There is also a toggle to turn off image downloads completely if required.

## Limitations and Known Issues:
- Unfortunately two way highlight syncing is not possible as the Readwise Reader API does not provide the location data required by KOReader.
- Highlights that this plugin creates in Readwise are not anchored inside the original article in Readwise Reader, so tapping one will not jump to the passage. This is an API limitation - see the discussion [here](https://github.com/tomtom800/readwisereader/issues/20). Neither the public Reader REST API nor Readwise's public MCP server offers any way to create a highlight against an existing Reader document (rechecked 2026-08-31; details in [ROADMAP.md](docs/ROADMAP.md)). Downloaded Reader documents and explicitly linked local books send the Reader document's title, author, and source URL, giving Readwise's v2 highlight API its best available grouping data; it is not a guaranteed Reader-document attachment.
- Exported highlights carry a stable `highlight_url` derived from the annotation's creation time, so editing a highlight in KOReader updates it in Readwise on the next sync instead of adding a second copy. Readwise documents this update path for a highlight's *text*; whether it also revises an already-uploaded note is unverified.
- Native reading position only travels one way, from Readwise Reader to KOReader. Readwise Reader publishes how far through a document you are, but its API has no field for storing a position, so the manual KOReader-progress note is only a visible percentage mirror, not a native Reader position update (rechecked 2026-09-09; details in [ROADMAP.md](docs/ROADMAP.md)). Marking an article "finished" in KOReader still archives it in Readwise Reader. The position that is carried across is approximate, because Readwise Reader and KOReader lay the same article out differently.
- Books and PDFs already on your ereader cannot be uploaded to Readwise Reader from KOReader. The Readwise Reader API accepts a URL or a block of HTML, but has no file upload; EPUBs and PDFs can only be added by dragging them into the Readwise Reader web app or sharing to it from a phone. Highlights you make in those books are still exported to Readwise as normal.
- A local-book link is keyed to that file's exact device path. If you move, rename, or replace the file, link it again. A highlight record without a local file path (for example, an unmatched Kindle My Clippings entry) cannot use a local-book link.
- **Linked book progress** is manual and one book at a time. Sending progress writes only a marked `KOReader progress: N%` line to the Reader document note, preserving other note text. Applying Reader progress moves the open KOReader book to Reader's percentage approximately; it does not create a continuous progress sync.
- I am not planning to add any options to style the documents. However there are lots of tweaks you can apply as a user - see [here](https://koreader.rocks/user_guide/#L1-customizingappearance). 

## Link a local book to Reader

1. Open the sideloaded book in KOReader.
2. Choose **Readwise Reader → Link current book to Reader…**.
3. Search the Reader library, inspect the candidates if necessary, and select the exact book.
4. Choose **Readwise Reader → Advanced sync → Export highlights to Readwise** whenever you want to send highlights. This path exports highlights only; it does not download Reader HTML.

The filename is prefilled solely as a search suggestion. You always choose the target manually, and **Remove Reader link for current book** reverses the association.

For a linked, open local book, choose **Readwise Reader → Linked book progress** to:

- Send the current KOReader percentage to the Reader document note.
- Apply the Reader percentage to the current KOReader book after confirmation.
- Remove only the marked KOReader-progress line from the Reader note after confirmation.

## Installation:
- Download the [ZIP of the plugin](https://github.com/Endle/readwisereader/releases/). Extract it.
- Attach your ereader to your computer. Copy the `readwisereader.koplugin` folder containing _meta.lua and main.lua from the extracted folder to the `koreader/plugins` folder. Restart KOReader.
- The plugin requires a Readwise access token, which subscribers can obtain [here](https://readwise.io/access_token).
- The token can be typed in manually in the Readwise Reader/Settings/Configure Readwise Reader menu, but this is difficult to do correctly. It's easy to be confused by the letter O and the number 0, or the lowercase letter l, the uppercase letter I and the numeral 1. If the plugin is not working, check this first.
- You may prefer to copy and paste the access token directly from your computer into KOReader settings. To do this, first set the folder you want to download to in the Readwise Reader/Settings/Download folder menu. This will create the file koreader/settings/readwisereader.lua. Add the access token to this file in the following format:

```
-- ./settings/readwisereader.lua
return {
    ["readwisereader"] = {
        ["access_token"] = "{access token}",
        ["available_locations"] = {},
        ["available_tags"] = {},
        ["directory"] = "{download location}",
        ["document_categories"] = {},
        ["document_locations"] = {},
        ["document_tags"] = {},
        ["excluded_locations"] = {},
        ["excluded_tags"] = {},
        ["max_articles_to_download"] = 0,  -- 0 = unlimited
    },
}
```
- The extension is then activated by selecting “Sync” in the Readwise Reader menu.
- By default, the extension will be added to the file menu with the prefix NEW:. The plugin will work in this format, but to remove the NEW: prefix and to move it to a different menu, add a line for  `"readwisereader",` in the appropriate place in koreader/frontend/ui/elements/filemanager_menu_order.lua

## Bug reporting
If reporting a bug, especially one that causes KOReader to crash, please share logging from your device in koreader/crash.log. Errors and crashes are clearly marked. To ensure that you just capture the relevant logs, delete the file, let KOReader regenerate it for you, then save the file after the issue has occurred.

## Development
Notes for devs and power-users. Don't proceed unless you know the meaning of each step.

## Project planning

- [Architecture and API capability matrix](docs/ARCHITECTURE.md)
- [Phased roadmap](docs/ROADMAP.md)
- [Phase 1 build and Kindle verification plan](docs/PHASE-1.md)

### Test KOReader on Linux PC
KOReader has [Linux release](https://github.com/koreader/koreader/wiki/Installation-on-desktop-linux), so it's a breeze to test this plugin on Linux.

1. Install KOReader [via Flatpak](https://flathub.org/en/apps/rocks.koreader.KOReader)
2. `git clone git@github.com:Endle/readwisereader.git`
3. Check plugin directory `$HOME/.var/app/rocks.koreader.KOReader/config/koreader/plugins` - Thanks to [MountainToppish](https://www.reddit.com/r/koreader/comments/1mt7g9x/how_to_add_plugins_to_koreader_installed_from/)
4. Install the plugin by `cd  $HOME/.var/app/rocks.koreader.KOReader/config/koreader/plugins && ln -s $HOME/<source_path>/readwisereader.koplugin`
5. Restart KOReader
