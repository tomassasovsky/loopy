# segno update server

Static host for Loopy/segno updates — appliance RAUC bundles + a JSON manifest the
Pi polls (and desktop Sparkle/WinSparkle appcasts later). Runs behind **Nginx Proxy
Manager** (a separate container), which reverse-proxies `https://segno.aquiles.dev`
to this container as `segno-updates:3029` over a shared Docker network.

## Layout served
```
/updates/appliance/manifest.json     # the Pi reads this
/updates/appliance/loopy-appliance-<v>.raucb   # signed RAUC bundle(s)
/updates/macos/appcast.xml   (later)
/updates/windows/appcast.xml (later)
```

`manifest.json` schema:
```json
{ "version": 3, "bundle": "loopy-appliance-3.raucb", "sha256": "<hex>", "notes": "..." }
```
The Pi OTA client compares `version` to the running build; if newer it downloads
`bundle` from the same dir, verifies `sha256`, then `rauc install`s it (RAUC also
verifies the bundle's own X.509 signature — the manifest is not the security
boundary, the signature is).

## Deploy on Portainer (with Nginx Proxy Manager)
1. Find NPM's Docker network: Portainer → Networks (e.g. `nginxproxymanager_default`).
   Put that name in `docker-compose.yml` under `networks.npm.name`.
2. Portainer → Stacks → Add stack. It needs `default.conf` and the `www/` tree next
   to the compose on the host — clone this `deploy/server/` dir onto the host and
   point the stack at it, or use a Portainer "git repository" stack targeting this
   path. Deploy.
3. In **Nginx Proxy Manager** → Proxy Hosts → Add:
   - Domain: `segno.aquiles.dev`
   - Forward Hostname/IP: `segno-updates`  ·  Forward Port: `3029`  ·  Scheme: `http`
   - Enable SSL (Let's Encrypt) as usual.
   (If you'd rather not share a network, uncomment `ports: ["3029:3029"]` in the
   compose and point NPM at `<docker-host-ip>:3029` instead.)

Verify: `curl https://segno.aquiles.dev/healthz` → `ok`, and
`curl https://segno.aquiles.dev/updates/appliance/manifest.json`.

## Publishing an update (done by the pipeline / by hand)
Drop the signed `*.raucb` into `www/updates/appliance/`, then write `manifest.json`
with the new `version`, `bundle` filename and its `sha256`. The container serves
`www/` read-only, so publishing is just updating files in this dir on the host
(`no-cache` headers mean the Pi sees changes immediately).
