# Author Info for KOReader

Browse your library by author, with a photo and a short bio of each author.

- **Main menu → Authors** (above Favorites). For one-tap access, assign
  the **Authors** action to a gesture: Settings → Taps and gestures →
  Gesture manager → pick a gesture (e.g. tapping the top-left corner) →
  General → Authors.
- When the file browser shows covers, authors appear in the same grid, with
  each author's photo and name. In list or classic modes they appear in
  KOReader's standard list.
- **Tap an author** to see their books in the file browser's display style.
  The back arrow returns to the authors, and the ⓘ button shows **Author
  information**.
- **Hold an author** to view, find or replace (online), or remove their
  information or their image, each on its own. Buttons with nothing to act
  on are greyed out.
- **Author information** is laid out like KOReader's Book information:
  name, years, country, language, notable works, bio (tap to read), photo (tap
  to display), number of books in the library, time spent reading them
  (from KOReader's Statistics, in your duration format), and sources. Tap the
  sources to read the author's full Wikipedia page in KOReader's Wikipedia
  viewer, which can also save it as an EPUB.
- The **☰ button** has:
  - **Sort by:** first name, last name, number of books or recently read,
    optionally reversed. For first name, a name written "Le Guin, Ursula K."
    is read as "Ursula K. Le Guin". For last name, the family name from Wikidata is
    used when the author's name contains it ("Liu Cixin" → Liu). Otherwise a
    name written "Le Guin, Ursula K." sorts by the part before the comma,
    and other names by the last word together with particles before it
    ("Walter de la Mare" → de la Mare), skipping suffixes like "Jr.".
  - **Filter:** by keywords, as in Collections: an author is shown when
    any of their books match, and only the matching books are listed when
    you tap them. By the author's language (the languages they wrote in,
    a rough guide to the literature they belong to) and country, once their
    information has been looked up. And by status:
    - **New** / **Reading:** authors with a book that is new or in progress.
    - **Read:** authors with at least one finished book.
    - **Unread:** authors with no finished book at all.
  - **Find missing:** look up the images, information, or both, of the
    authors shown that don't have them yet. The device is kept awake until
    the lookup finishes. Authors are looked up on Open Library one by one,
    then on Wikidata many at a time, then their bios. When a site asks to
    slow down, the lookup waits a minute and carries on (and stops if it
    asks again). Information that couldn't be looked up completely, because
    a site was busy or didn't answer, isn't saved, so the next Find missing
    tries those authors again.
  - **Clear:** delete the saved images, information, or both, of the
    authors shown (images include ones you added yourself). Use Find
    missing afterwards to look them up afresh. **Prune authors** deletes
    what is saved for authors who no longer have books in the library,
    as Cover browser's "Prune cache of removed books" does for books.

  These choices are remembered for next time, as KOReader does
  for Collections.

Books with several authors are listed under each of them.

## Where things come from

- Authors come from the Cover browser plugin's book information cache, so
  books show up once KOReader has shown their covers. Only books inside the
  home folder are included.
- Photos come from Open Library, or from Wikipedia when Open Library has
  none. A Wikipedia page is used only if its description says the person is
  a writer. Nothing is downloaded unless you ask.
- Photos are saved in `koreader/authorinfo/<Author Name>.jpg`. You can put
  your own JPEG or PNG there under the same name.
- Author information starts from the same Open Library match. Details
  (names, country, languages, years, notable works) come from Wikidata,
  with labels in KOReader's language where available. The bio is the
  introduction of the author's Wikipedia page (everything before its first
  heading) in KOReader's language, else in English, else Open Library's
  bio. Its first paragraph is Wikipedia's tidied page summary, which leaves
  out the brackets after the name (dates, pronunciation). Older authors'
  historical countries are named by today's country (e.g. "United Kingdom
  of Great Britain and Ireland" → United Kingdom) where that is
  unambiguous.
- Information is saved beside the photo, in
  `koreader/authorinfo/<Author Name>.json`.

## Install

Download `authorinfo.koplugin.zip` from the
[latest release](https://github.com/SandaruLJ/koreader-authorinfo/releases/latest)
and unzip it into KOReader's `plugins` folder, so that it holds an
`authorinfo.koplugin` folder. To update, unzip a newer release over it; your
author images, information and settings are kept elsewhere. Requires the
Cover browser plugin (bundled with KOReader).

## Releasing

Bump `version` in `_meta.lua`, commit and push to `main`. The release
workflow checks that every Lua file compiles, then publishes `v<version>`
with the zip and the commits since the previous release.

## Credits and license

AGPL-3.0. The photo lookup is adapted from
[Bookshelf](https://github.com/AndyHazz/bookshelf.koplugin) (AGPL-3.0) by way
of ZenOS (GPL-3.0), which also supplied the HTTPS client.
