# StickerLab

App iOS per creare, modificare e fare il backup di pacchetti di sticker per WhatsApp.

## Funzioni

- **Importazione**: galleria (foto, GIF, video, Live Photo), app File, link.
- **Link automatici**:
  - **7TV**: emote statiche e animate, set completi, set di un utente, ricerca e popolari nella scheda 7TV.
  - **Pinterest**: foto, GIF e video, anche con link `pin.it`.
  - Link diretti a immagini, GIF, WebP e MP4, oppure pagine con anteprima Open Graph.
  - **cobalt** (facoltativo, con un tuo server): Instagram, TikTok, X, Reddit…
  - **Browser integrato**: "Estrai da questa pagina" oppure "Media nella pagina".
- **Editor**: zoom, posizione, rotazione, riempimento, testo con contorno, taglio di GIF e video, rimozione automatica dello sfondo (iOS 17+), emoji.
- **WhatsApp**: conversione automatica a 512×512 WebP entro i limiti (100 KB statici, 500 KB e 10 s animati) e invio con "Aggiungi a WhatsApp".
- **Backup**: `.zip` completo o per singolo pacchetto, importazione di backup e di `.wastickers` (Android), esportazione `.wastickers`.

## Build

Non serve un Mac: GitHub Actions genera il progetto con XcodeGen e compila un'IPA **non firmata**.

- A ogni push su `main`: release **latest** con `StickerLab.ipa`
  (`https://github.com/<utente>/StickerLab/releases/download/latest/StickerLab.ipa`).
- Tag `v1.0.0` → release con versione.
- Il workflow **Screenshots** avvia l'app nel simulatore e salva le schermate come artifact.

## Installazione (sideload)

1. Scarica `StickerLab.ipa` dalla release.
2. Installala con **Sideloadly** (PC) oppure **AltStore / SideStore** (iPhone).
3. Con un Apple ID gratuito l'app va rifirmata ogni 7 giorni (AltStore/SideStore lo fanno da soli).

## Condividere link all'app

Crea un Comando Rapido che riceve URL dal menu Condividi e apre
`stickerlab://import?url=<URL codificato>`.

## Struttura

```
project.yml                 progetto XcodeGen
StickerLab/App              entry point, stato, utilità, dati demo
StickerLab/Models           pacchetti e archivio su disco
StickerLab/Media            decodifica, rendering, codec WebP (libwebp), encoder WhatsApp
StickerLab/Import           downloader, 7TV, Pinterest, cobalt, estrattore HTML
StickerLab/Export           invio a WhatsApp, backup
StickerLab/Views            interfaccia SwiftUI
```
