# iliad-unifi

[English](README.md) · **Italiano**

Usa una linea FTTH **Iliad con l'opzione "modem libero" (net neutrality) direttamente su un gateway UniFi**,
senza iliadbox davanti. Sfrutta il tipo di WAN *IPv4 Over IPv6 → IPIP* di UniFi stesso (UniFi Network 11.0.81
Early Access e successive) più un piccolo script di supporto che copre i punti in cui Iliad si discosta dai
provider giapponesi per cui quella funzione è stata scritta.

**Stato (7 ottobre 2026):** funziona su una linea Iliad 5 Gbps (5000/700) con un **UniFi Cloud Gateway Fiber** e
un **UDM Pro**, entrambi con UniFi OS 6.0.11 e UniFi Network 11.0.81 EA. Il tipo IPIP è segnato *Labs* in una
release Early Access e può cambiare da un aggiornamento all'altro. Non ancora provato su una linea GPON 2,5 Gbps:
le segnalazioni sono benvenute.

Le voci di menu sono riportate come appaiono nell'interfaccia UniFi in inglese.

## Come Iliad consegna l'IPv4

La rete di accesso di Iliad è solo IPv6: **VLAN 836**, DHCPv6 con un **/60 delegato**. L'IPv4 viaggia in un
**tunnel IPv4-in-IPv6 (RFC 2473)** verso un Border Relay, con un **IPv4 pubblico statico** dal lato cliente e il
NAT fatto in casa. I valori sono nell'*Area Personale → Informazioni Net Neutrality*:

| Campo del portale | Significato |
|---|---|
| `IP6_NETWORK` | il /60 delegato |
| `IP6_TUNNEL_LOCAL` | indirizzo locale del tunnel = primo /64 del /60 + un interface ID RFC 7597 `0:<IPv4>:0` |
| `IP6_TUNNEL_GW` | il Border Relay |
| `IP4_TUNNEL` | il tuo IPv4 pubblico statico |

In pratica è MAP-E con un IPv4 intero (1:1), la stessa forma del servizio giapponese "v6 Plus" a IP fisso: per
questo il profilo v6 Plus di UniFi si adatta.

## Cosa fa UniFi 11.0.81 e cosa aggiunge `native.sh`

*Settings → Internet → IPv4 Over IPv6 → IPIP → v6 Plus* accetta un Border Relay, un interface ID e un IPv4 fisso.
Il controller li salva, costruisce il tunnel e tratta l'IPv4 pubblico come qualsiasi altra WAN: NAT, firewall,
monitoraggio della WAN, failover. Su Iliad però non si alza da solo:

| # | Problema | Cosa fa `native.sh` |
|---|---|---|
| 1 | L'indirizzo locale del tunnel viene ricavato dal **primo** IPv6 globale della WAN. Su Iliad è il /128 del DHCPv6, preso da un prefisso di accesso separato che Iliad non instrada affatto. | Mette `<primo /64 del /60>::46/64` (`nodad noprefixroute`) sulla WAN e tiene un indirizzo di quel /64 in cima alla lista. |
| 2 | Il tunnel viene costruito solo dopo che una chiamata HTTP di "address update" al provider giapponese va a buon fine, con login obbligatorio. Se fallisce una volta, non riprova finché l'IPv6 della WAN non cambia. | Punta l'override per-WAN di UniFi (`/data/udapi-config/jpix.<wan>.address_update`) a un piccolo responder sul gateway stesso, così il login fittizio non esce mai dal gateway, e sollecita di nuovo UniFi se l'IPv4 resta giù per 60 s. |
| 3 | Con una VLAN sulla WAN, Network 11.0.81 aggancia il tunnel alla **porta** (`eth9`) invece che all'**interfaccia VLAN** (`eth9.836`). I parametri giusti vengono calcolati, ma il tunnel resta a `::ffff:192.0.0.2 → any`. | Riaggancia il tunnel all'interfaccia VLAN dopo ogni provisioning (circa 4 s di interruzione). |
| 4 | **Trappola:** salvare quella WAN dall'**app UniFi per iOS**, che non conosce il tipo IPIP, la trasforma senza avvisare in DHCP e cancella Border Relay, interface ID e login. Iliad cade. | Guardia opzionale: con una chiave API UniFi riconosce esattamente quello stato e riscrive le impostazioni IPIP (al massimo 3 volte all'ora). |

Il resto è tutto di UniFi. Come servizio (`iliad-native`) lo script ricontrolla ogni 5 s e si mette a riposo se la
WAN non è più di tipo IPIP.

## Risultati (6 ottobre 2026, Iliad 5 Gbps)

| | UCG Fiber | UDM Pro |
|---|---|---|
| Speed test di UniFi (termina sul gateway) | 3688 / 684 Mb/s | 4449 / 686 Mb/s |
| Inoltrato a un client in LAN su 2 × 2.5G | **3,70 Gb/s** | **4,32 Gb/s** (IPS spento, RPS regolato) |
| Inoltrato, impostazioni predefinite | 2,2–2,3 Gb/s su un solo link 2.5G (limite del client) | 1,80 Gb/s con IPS acceso |
| Cosa lo limita | una sola coda RX su cpu0; ECM/SFE di Qualcomm accelera ogni flusso del tunnel | la CPU: nessun hardware di offload, tutti e quattro i core ~90 % |

L'upload è comunque quello del piano, 700 Mb/s. Per confronto, un'iliadbox davanti a un router UniFi gli arriva
attraverso la sua unica porta 2.5G, quindi il router vede al massimo circa 2,35 Gb/s.

## Requisiti

- **Gateway:** UniFi OS 6.0.11 o successivo con **UniFi Network 11.0.81 o successivo** (Early Access al momento in
  cui scrivo). Provati: UCG Fiber, UDM Pro. Altri gateway che offrono il tipo IPIP probabilmente funzionano, ma non
  sono stati provati.
- **SSH** attivo sul gateway (impostazioni della console UniFi OS, *SSH* con password) e la tua chiave installata
  (`ssh-copy-id root@<gateway>`).
- **L'ONT.** Sull'offerta 5 Gbps è la scatola ONT esterna di Iliad, **Freebox F-MDONU05A**: la fibra va nel suo
  alloggiamento FIBER, e un **DAC SFP+ 10G** va dall'alloggiamento BOX alla porta WAN SFP+ del gateway. Un DAC 10G
  da 20 cm ha agganciato a 10G e ha portato più di 4 Gb/s. Sulle linee GPON 2,5 Gbps con un ONT esterno su RJ45
  dovrebbe valere lo stesso schema, ma qui non è ancora stato provato.
- **Indirizzo MAC.** Iliad vede il **MAC della porta WAN del router** (l'ONT è un bridge di livello 2). Usa un MAC
  già registrato nel portale: o perché è proprio quello della porta, o tramite il *MAC Address Clone* di UniFi. Il
  portale ha pochi slot, che non si potevano cancellare (2024), e una nuova registrazione può richiedere fino a 48 ore.
- Un Mac o un computer Linux con `ssh` e `tar` per copiare il kit.

## Installazione

1. **Configurazione.** `mkdir -p local && cp iliad.conf.example local/iliad.conf` e compila i quattro valori del
   portale, `WAN_PORT_IF` (la porta verso l'ONT: su un UDM Pro `eth9` = porta 10, la WAN SFP+) e `REGISTERED_MAC`.
   `local/` è escluso da git.
2. **Copia il kit:** `./push.sh root@<gateway>` (lo installa in `/data/iliad`, che sopravvive ai riavvii).
3. **Verifica preliminare (non cambia nulla):** `ssh root@<gateway> /data/iliad/preflight.sh`. Controlla che il
   firmware abbia la funzione `ipip_jpix`, le porte e i moduli SFP, la WAN attuale, e se il MAC della porta WAN
   corrisponde a quello registrato. Tieni l'output e uno screenshot delle impostazioni WAN attuali per poter tornare
   indietro.
4. **Cosa scrivere in UniFi:** `ILIAD_CONF=local/iliad.conf ./native.sh ui` (sul tuo computer) stampa tutti i campi.
5. **Interfaccia web di UniFi, non l'app** → *Settings → Internet →* la porta WAN con l'ONT:
   - VLAN ID **836**; MAC Address Clone se serve.
   - IPv4: **IPv4 Over IPv6 → IPIP → v6 Plus**. Border Relay = `IP6_TUNNEL_GW`; **Interface ID nella forma
     compressa con `::`** (per 192.0.2.43: `::c000:22b:0`; la forma a quattro gruppi `0:c000:22b:0` manda in crash
     il calcolatore di UniFi); IPv4 = `IP4_TUNNEL` con maschera /32; username e password = 1–20 lettere e cifre
     qualsiasi (Iliad non ha login; quella chiamata la risponde lo script, sul gateway).
   - IPv6: **DHCPv6, prefix delegation size 60**.
   - Reti LAN: niente IPv6, oppure un IPv6 prefix ID diverso da 0 (il primo /64 è del tunnel).
   - *Test*, poi *Confirm*. Un *Test* non confermato torna indietro dopo 5 minuti.
6. **Installa lo script:** `ssh root@<gateway> /data/iliad/native.sh check`, poi `… native.sh install`.
   `native.sh status` deve mostrare il tunnel di UniFi con local = `IP6_TUNNEL_LOCAL`, l'IPv4 pubblico sopra e i
   ping che rispondono. Nell'interfaccia la WAN diventa verde.
7. **Controlla:** da un computer in LAN, `curl -4 -s https://1.1.1.1/cdn-cgi/trace` mostra il tuo IPv4 statico.
   Poi fai una scansione delle porte di quell'IPv4 dall'esterno: non deve risultare aperto nulla. (Sul percorso
   nativo il firewall di UniFi copre anche il tunnel, ma qui una scansione pulita dall'esterno non è ancora stata
   fatta: controlla la tua.)
8. **Guardia opzionale contro l'app iOS:** crea una chiave API in *UniFi OS → Control Plane → Integrations* e
   salvala sul gateway con `umask 077; cat > /data/iliad/api.key` (solo root, mai dentro `iliad.conf`).
   `native.sh guard-check` (sola lettura) prova la chiave e mostra cosa farebbe la guardia. La chiave può cambiare
   tutta la configurazione di rete: trattala come la password di amministratore. Per spegnere la guardia:
   `NATIVE_GUARD=off` nella configurazione oppure `touch /data/iliad/guard.off`.

**Per tornare indietro:** `native.sh uninstall`, rimetti la WAN com'era in UniFi, sposta la fibra di nuovo
nell'iliadbox.

**Dopo un aggiornamento del firmware** controlla `native.sh status`. Il kit in `/data/iliad` resta; se
l'aggiornamento ha tolto il servizio, rilancia `native.sh install`.

## Ottimizzazione

- **UDM Pro** (Annapurna Alpine, senza motore di accelerazione: il tunnel viene decapsulato via software):
  - spegni l'**Intrusion Prevention**: con l'IPS acceso l'inoltro si fermava a 1,80 Gb/s;
  - imposta `NATIVE_RXHASH=off` e `NATIVE_TUN_RPS` su tutti i core **tranne** quello che serve la coda RX del
    tunnel. La scheda di rete dà a ogni pacchetto del tunnel lo stesso hash, calcolato sull'intestazione esterna,
    e così il lavoro si ammucchia su un solo core. Trovi il core sotto carico con `grep rx-comp /proc/interrupts`.
    Qui era cpu2, quindi la maschera era `b` (core 0, 1, 3). La coda viene scelta per hash: ricontrolla dopo un
    riavvio.
- **UCG Fiber:** niente da regolare. Il fast path ECM/SFE di Qualcomm prende in carico il tunnel di UniFi;
  `tools/fastpath.sh` mostra i suoi contatori e il carico per core. Spegnere il GRO peggiorava le cose.
- `tools/speed.sh root@<gateway> [flussi] [secondi]` (da un computer in LAN) scarica da Cloudflare mentre il gateway
  campiona il carico per core e il traffico sulle interfacce.

## Comandi

`native.sh check | ui | up | down | kick | status | guard-check | install | uninstall | run`

- `check`, `ui`, `status`, `guard-check` non cambiano nulla.
- `up` / `down` applicano o tolgono una volta sola i pezzi dello script; `install` / `uninstall` gestiscono il
  servizio.
- `kick` fa ricalcolare subito il tunnel a UniFi.

## Firmware più vecchi: il tunnel fatto a mano

Prima della 11.0.81 il tipo IPIP non c'è. Gli script precedenti costruiscono il tunnel a mano e sono stati provati su
un UDM Pro con UniFi OS 6.0.10 (29 settembre 2026). Lì la WAN di UniFi è impostata su VLAN 836, DS-Lite (AFTR =
Border Relay) e DHCPv6 con PD 60, solo per far salire la VLAN e l'IPv6.

| Script | Cosa cambia |
|---|---|
| `selftest.sh up\|test\|status\|down` | un tunnel tutto suo, `iltest0`: prova la linea dal gateway senza toccare la LAN |
| `lan.sh up\|keep\|status\|down` | l'IPv4 della LAN passa da `iltest0`; si annulla da solo dopo 10 minuti se non dai `keep` |
| `iliad-wan.sh install\|uninstall\|status` | servizio permanente: tunnel `iliad0`, tabella di routing e catene proprie, protezione in ingresso, failover via ping sull'altra WAN di UniFi |
| `udapi-plan.sh` | anteprima in sola lettura degli oggetti `ipip_jpix` di UniFi (scritto prima che il controller li supportasse) |

Funziona, ma l'interfaccia mostra quella WAN in rosso, il traffico del gateway stesso resta sull'altra WAN, e le
regole di traffico di UniFi vengono scavalcate per ciò che passa nel tunnel. Se il tuo firmware ha il percorso
nativo, usa quello.

## Cose imparate per strada

- Iliad instrada **solo il /60 delegato**. Il traffico che parte dal /128 DHCPv6 della WAN non riceve risposta.
- Iliad annuncia un MTU fino a 1700 sul link di accesso, quindi una WAN con MTU 1540 permette al tunnel di portare
  pacchetti pieni da 1500 byte; sotto quel valore il TCP dipende dal clamping dell'MSS.
- Un `ip6tnl` Linux fatto a mano richiede `encaplimit none`. Altrimenti aggiunge un'intestazione Destination
  Options, che i relay spesso scartano.
- Il lato BOX della F-MDONU05A risultava solo 1G prima di un aggiornamento firmware di febbraio 2024. Oggi aggancia
  a 10G con un DAC 10G.
- Per scoprire chi o cosa ha cambiato un'impostazione della WAN, il registro attività degli amministratori di UniFi
  (`POST /proxy/network/v2/api/site/default/system-log/admin-activity`) elenca i valori vecchi e nuovi in
  `updates[]`. È così che è venuta fuori la cancellazione fatta dall'app iOS.

## Contesto

Prima della 11.0.81, il supporto Ubiquiti aveva confermato per iscritto (caso 5924768, 2 settembre 2026) che non
erano supportati né parametri MAP-E personalizzati né un IPv4 statico sul tunnel DS-Lite. La richiesta di
funzionalità, con le specifiche pubblicate da Iliad, è sulla community UniFi (in inglese):
[Generic MAP-E parameters — Iliad Italia, fully specified](https://community.ui.com/questions/FEATURE-REQUEST-Generic-MAP-E-parameters-the-code-already-ships-Iliad-Italia-fully-specified/b34bd953-1295-4459-98eb-056b45e03bf2).
Se UniFi sistema i problemi 1–3 (indirizzo locale dal prefisso delegato, address update opzionale, aggancio
all'interfaccia VLAN), allo script resta solo la guardia contro l'app iOS.

## Avvertenze

Non ufficiale, e senza alcun legame con Iliad o Ubiquiti né loro approvazione. Gli script girano come root sul tuo
gateway e possono lasciarti senza internet: leggili prima di lanciarli, e tieniti una via di ritorno (l'iliadbox, una
seconda WAN). Usalo a tuo rischio. Licenza MIT.
