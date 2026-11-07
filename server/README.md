# Server cobalt su AWS (per StickerLab)

cobalt estrae foto e video da Instagram, TikTok, X, Reddit, Tumblr e altri siti.
Pinterest e 7TV funzionano anche senza questo server.

## Cosa viene installato
- **cobalt 11** (Docker), accessibile solo con la tua API key
- **Caddy**: HTTPS automatico con Let's Encrypt
- dominio gratuito automatico `IP-CON-TRATTINI.sslip.io`, oppure il tuo dominio
- aggiornamento automatico di cobalt ogni giorno

## Creare il server (console AWS, circa 5 minuti)

1. **EC2 → Launch instance**
   - Name: `stickerlab-cobalt`
   - AMI: **Ubuntu Server 24.04 LTS** (x86)
   - Instance type: **t3.micro** (free tier) oppure t3.small
   - Key pair: facoltativa (si può entrare dal browser con *EC2 Instance Connect*)
2. **Network settings → Edit**
   - Security group: consenti **HTTP (80)** e **HTTPS (443)** da *Anywhere*
   - SSH (22) solo da *My IP*, se ti serve
3. **Advanced details → User data**: incolla tutto il contenuto di [`user-data.sh`](user-data.sh).
   Per usare un tuo dominio, compila `COBALT_DOMAIN=""` in cima.
4. **Launch instance** e attendi 3-4 minuti.

## Prendere URL e API key
- EC2 → seleziona l'istanza → **Actions → Monitor and troubleshoot → Get system log**: cerca `=== StickerLab / cobalt ===`
- oppure **Connect → EC2 Instance Connect** e lancia: `sudo cat /opt/cobalt/CREDENTIALS.txt`

Poi in StickerLab: **Impostazioni → Server cobalt** → incolla URL e API key → *Prova connessione*.

## IP fisso (consigliato)
Senza Elastic IP, l'indirizzo cambia se fermi e riavvii l'istanza.
1. EC2 → **Elastic IPs → Allocate** → **Associate** all'istanza
2. Connettiti e lancia: `sudo /opt/cobalt/reconfigure.sh`
3. Aggiorna l'URL nell'app.

Un Elastic IP associato a un'istanza accesa costa circa 3,6 $/mese (IPv4 pubblico), come qualsiasi IP pubblico.

## Costi indicativi
- t3.micro: gratis nel free tier, poi circa 8 $/mese
- traffico in uscita: trascurabile per gli sticker

## Comandi utili
```bash
cd /opt/cobalt
sudo docker compose ps          # stato
sudo docker compose logs -f     # log
sudo /etc/cron.daily/cobalt-update   # aggiorna subito
```
