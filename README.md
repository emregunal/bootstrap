# OpenCode Bootstrap

Bir OpenCode geliştirme ortamının tek kaynağı. Skill'ler, MCP server'ları,
global agent kuralları ve yardımcı komutlar tek repository'de tutulur; yeni bir
makinede tek komutla kurulur.

WSL Ubuntu / Linux odaklıdır, macOS'ta da çalışır.

```bash
git clone <repo-url> opencode-bootstrap
cd opencode-bootstrap
./bootstrap.sh
```

Sonrasında iki global komut kullanılabilir:

```bash
opencode-sync      # repo'yu çek, değişiklikleri lokale uygula
opencode-doctor    # kurulumun sağlığını kontrol et (hiçbir şeyi değiştirmez)
```

---

## Ne işe yarar?

`bootstrap.sh` şunları yapar:

| Adım | Ne yapar |
|---|---|
| Environment | `git`, `node`, `npm`, `npx` kontrolü; WSL/Linux/macOS tespiti |
| OpenCode | Kurulu mu, config dizini nerede |
| Backup | `~/.config/opencode` → `~/.config/opencode.backup-YYYYMMDD-HHMMSS` |
| Skills | `skills/*.conf` içindeki skill'leri global olarak kurar |
| MCP | `mcp/mcps.json` içindeki server'ları OpenCode config'ine merge eder |
| Config | Global agent kurallarını kurar ve `instructions` alanına kaydeder |
| Aliases | `~/.local/bin/opencode-sync` ve `opencode-doctor` |
| Doctor | Sonuçta health check çalıştırır |

**Idempotent'tir.** Arka arkaya kaç kez çalıştırırsanız çalıştırın sonuç aynıdır.

### Mevcut kurulumunuz korunur

Bu repository yalnızca **sahiplendiği** alanlara dokunur:

- `mcp.*` altında `mcp/mcps.json`'da adı geçen server'lar
- `instructions` dizisindeki kendi kural dosyası girdisi
- `~/.config/opencode/opencode-bootstrap/` dizini (tamamen bu repo'nun)
- `~/.local/bin/opencode-sync`, `~/.local/bin/opencode-doctor`
- Shell config'inizdeki `# >>> opencode-bootstrap >>>` bloğu

Provider ayarlarınız, model tercihleriniz, agent'larınız, tema, keybind'ler,
kendi elinizle eklediğiniz MCP server'lar ve `auth.json` içindeki
kimlik bilgileri **okunmaz ve değiştirilmez**. İlk yazma işleminden önce config
dizininin tamamının yedeği alınır.

Zaten sizin tanımladığınız isimde bir MCP server varsa üzerine yazılmaz —
"already configured by you" uyarısı verilir ve olduğu gibi bırakılır.

---

## Gereksinimler

| Araç | Neden |
|---|---|
| `git` | repo'yu çekmek ve `opencode-sync` için |
| `node` + `npm`/`npx` | skills CLI ve config merge için |
| `opencode` | ortamın kendisi |

Ubuntu / WSL'de eksikse:

```bash
sudo apt update && sudo apt install -y git curl
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt install -y nodejs
curl -fsSL https://opencode.ai/install | bash
```

---

## Hızlı kurulum

```bash
git clone <repo-url> opencode-bootstrap
cd opencode-bootstrap

cp .env.example .env      # opsiyonel — API key'leriniz varsa doldurun
./bootstrap.sh

source ~/.bashrc          # veya ~/.zshrc
opencode-doctor
```

`.env` olmadan da kurulum tamamlanır; API key isteyen MCP server'lar
yapılandırılır ama kimlik doğrulaması yapamaz ve doctor bunu uyarı olarak
gösterir.

---

## Yeni bilgisayar kurulumu

```bash
# 1. Bağımlılıklar (yukarıdaki Ubuntu/WSL bloğu)
# 2. Repo
git clone <repo-url> ~/opencode-bootstrap
cd ~/opencode-bootstrap

# 3. Secret'lar — .env repo'da değildir, elle taşınır
cp .env.example .env
$EDITOR .env

# 4. Kur
./bootstrap.sh

# 5. Yeni shell aç
exec $SHELL -l
opencode-doctor
```

---

## Profiller

Her şeyi kurmak zorunda değilsiniz:

```bash
./bootstrap.sh --profile frontend   # frontend.conf
./bootstrap.sh --profile backend    # backend.conf + database.conf
./bootstrap.sh --profile devops     # devops.conf + security.conf
./bootstrap.sh --profile testing    # testing.conf
./bootstrap.sh --profile full       # hepsi (varsayılan)
```

Herhangi bir manifest adı da profil olarak kullanılabilir
(`--profile database`, `--profile security`).

Profiller `skills/profiles.conf` içinde tanımlıdır:

```text
frontend|frontend
backend|backend,database
devops|devops,security
full|frontend,backend,database,devops,testing,security
```

Diğer bayraklar:

```bash
./bootstrap.sh --dry-run        # ne yapacağını göster, hiçbir şeyi değiştirme
./bootstrap.sh --skip-skills    # sadece config + MCP + alias
./bootstrap.sh --skip-mcp       # MCP'ye dokunma
```

---

## Skill yönetimi

Skill'ler kategoriye göre ayrılmış manifest dosyalarında tutulur:

```text
skills/
├── frontend.conf     UI/UX, React, Next.js, animasyon
├── backend.conf      Node.js, TypeScript, REST API
├── database.conf     MySQL, SQL optimizasyon
├── devops.conf       Docker, Linux, reverse proxy, deployment, Git
├── testing.conf      TDD, web testing, sistematik debugging
├── security.conf     application security, security review
└── profiles.conf     profil tanımları
```

Kurulu skill listesi:

| Kategori | Skill | Kaynak |
|---|---|---|
| UI/UX | `ui-ux-pro-max` | `nextlevelbuilder/ui-ux-pro-max-skill` |
| UI/UX | `frontend-design` | `anthropics/skills` |
| UI/UX | `design-taste-frontend` | `leonxlnx/taste-skill` |
| UI/UX | `high-end-visual-design` | `leonxlnx/taste-skill` |
| Animasyon | `awwwards-animations` | `devmartinese/awwwards-animations-skill` |
| React | `vercel-react-best-practices` | `vercel-labs/agent-skills` |
| Next.js | `nextjs-app-router-patterns` | `wshobson/agents` |
| Node.js | `nodejs-backend-patterns` | `wshobson/agents` |
| TypeScript | `typescript-advanced-types` | `wshobson/agents` |
| REST API | `api-and-interface-design` | `addyosmani/agent-skills` |
| MySQL | `mysql` | `planetscale/database-skills` |
| SQL | `sql-optimization-patterns` | `wshobson/agents` |
| Docker | `multi-stage-dockerfile` | `github/awesome-copilot` |
| Docker | `docker-management` | `bagelhole/devops-security-agent-skills` |
| Linux | `linux-administration` | `bagelhole/devops-security-agent-skills` |
| Nginx | `reverse-proxy` | `bagelhole/devops-security-agent-skills` |
| Deployment | `deployment-pipeline-design` | `wshobson/agents` |
| Git | `git-workflow-and-versioning` | `addyosmani/agent-skills` |
| Testing | `test-driven-development` | `addyosmani/agent-skills` |
| Testing | `webapp-testing` | `anthropics/skills` |
| Debugging | `systematic-debugging` | `obra/superpowers` |
| Security | `security-and-hardening` | `addyosmani/agent-skills` |
| Security | `security-review` | `github/awesome-copilot` |

Skill'ler global olarak `~/.agents/skills/<name>/` altına kurulur. Bu, OpenCode'un
native global skill dizinlerinden biridir — ek bir symlink veya plugin gerekmez.

### Yeni skill ekleme

İlgili `.conf` dosyasına tek satır ekleyin:

```text
owner/repository|skill-name
```

Sonra:

```bash
opencode-sync
```

**`skill-name`, SKILL.md içindeki `name:` alanıdır** — repository'deki klasör adı
her zaman aynı olmayabilir. Örneğin `high-end-visual-design`,
`leonxlnx/taste-skill` içinde `skills/soft-skill/` klasöründe durur.

Doğru adı bulmak için:

```bash
npx skills@latest add owner/repository -l     # repo'daki skill'leri listele
npx skills@latest find "docker"               # ekosistemde ara
```

### Skill kaldırma

`.conf` dosyasından satırı silin, sonra:

```bash
npx skills@latest remove -g -s <skill-name> -y
```

---

## MCP yönetimi

MCP server'ları `mcp/mcps.json` içinde tanımlıdır. `config` bloğu doğrudan
OpenCode'un [MCP şeması](https://opencode.ai/docs/mcp-servers/) ile aynıdır ve
config'e olduğu gibi yazılır.

| Server | Tip | Gerekli env |
|---|---|---|
| `context7` | remote | `CONTEXT7_API_KEY` |
| `github` | remote | `GITHUB_TOKEN` |
| `playwright` | local (`npx @playwright/mcp`) | — |
| `filesystem` | local (`npx @modelcontextprotocol/server-filesystem`) | `MCP_FILESYSTEM_ROOT` (varsayılan `$HOME`) |

### Yeni MCP ekleme

`mcp/mcps.json` içindeki `servers` altına ekleyin:

```json
"my-server": {
  "requiresEnv": ["MY_API_KEY"],
  "config": {
    "type": "local",
    "command": ["npx", "-y", "some-mcp-package@latest"],
    "enabled": true,
    "environment": { "MY_API_KEY": "{env:MY_API_KEY}" }
  }
}
```

Remote bir server için:

```json
"my-remote": {
  "requiresEnv": ["MY_TOKEN"],
  "config": {
    "type": "remote",
    "url": "https://example.com/mcp",
    "enabled": true,
    "headers": { "Authorization": "Bearer {env:MY_TOKEN}" }
  }
}
```

`requiresEnv` yalnızca bootstrap'e aittir; config'e yazılmaz. Listedeki bir
değişken tanımsızsa uyarı verilir, kurulum durmaz.

Sonra `.env.example` dosyasına da anahtarı ekleyip `opencode-sync` çalıştırın.

Manifest'ten çıkardığınız bir server, `opencode-sync` sırasında config'den de
temizlenir (yalnızca bu repo'nun eklediyse).

---

## Secret yönetimi

**Hiçbir gerçek credential repository'ye girmez.**

- `.env` `.gitignore` içindedir; `.env.example` şablondur.
- Config dosyasına yazılan şey `{env:CONTEXT7_API_KEY}` gibi bir
  yer tutucudur, değerin kendisi değil.
- OpenCode bu yer tutucuyu kendi process environment'ından çözer. Repo'nun
  `.env`'ini görmediği için bootstrap değerleri
  `~/.config/opencode/opencode-bootstrap/env.sh` dosyasına (mode `0600`) yazar
  ve shell config'inize bu dosyayı source eden tek bir satır ekler.
- `env.sh` config dizinindedir, repository'de değildir — commit edilemez.
- OAuth/login akışı otomatikleştirilmez ve token toplanmaz. Eksik kimlik
  doğrulaması yalnızca raporlanır.

`.gitignore` en azından şunları kapsar: `.env`, `.env.*` (`.env.example` hariç),
`*.key`, `*.pem`, `credentials.json`, `secrets.json`, `auth.json`, `.netrc`.

Commit öncesi hızlı kontrol:

```bash
git status
git diff --cached
grep -rEn 'ghp_|github_pat_|sk-[A-Za-z0-9]|AIza[0-9A-Za-z_-]{35}' . --exclude-dir=.git
```

---

## Antigravity / OAuth

Antigravity üzerinden OpenCode'a giriş, topluluk tarafından yazılmış bir auth
plugin'i ile yapılır. Bu repository o plugin'i **kurmaz ve yapılandırmaz** —
yalnızca durumunu raporlar:

```text
✓ Antigravity plugin configured
✓ Antigravity authentication present
```

veya

```text
· Antigravity plugin not configured (optional)
```

Kimlik doğrulaması eksikse doctor sadece komutu gösterir
(`opencode auth login`). Token okuma, kopyalama veya toplama yapılmaz.

---

## Güncelleme

Repository'de bir skill veya MCP değiştiğinde, diğer makinede:

```bash
opencode-sync
```

Bu komut sırasıyla:

1. `git status` kontrol eder — çalışma dizini kirliyse **pull yapmaz**
2. Temizse `git pull --ff-only` çalıştırır (merge/rebase asla yapmaz)
3. Skill manifest'lerini uygular
4. MCP config'ini uygular
5. Agent kurallarını ve alias'ları senkronize eder
6. `doctor` çalıştırır

Repo'ya dokunmadan sadece yeniden uygulamak için:

```bash
opencode-sync --no-pull
opencode-sync --profile frontend
```

`./update.sh`, `opencode-sync` ile aynı script'tir.

---

## Doctor

```bash
opencode-doctor
```

Sistem, OpenCode, kimlik doğrulama, skill ve MCP durumunu kontrol eder.
**Hiçbir şeyi değiştirmez.** Sorun bulduğunda hemen altında çözümü gösterir:

```text
✗ Playwright MCP missing
  Fix: ./scripts/install-mcps.sh
```

Çıkış kodu: sorun yoksa `0`, varsa `1`. Uyarılar (opsiyonel parçalar) çıkış
kodunu etkilemez, böylece CI'da da kullanılabilir.

Tek bir profili kontrol etmek için:

```bash
PROFILE=frontend ./doctor.sh
```

---

## Sorun giderme

**`opencode-sync: command not found`**
`~/.local/bin` PATH'te değil. Yeni bir shell açın veya `source ~/.bashrc`.
Hâlâ olmuyorsa `./scripts/install-aliases.sh` çalıştırın.

**Bir skill kurulmuyor**
Diğerleri etkilenmez; başarısız olan açıkça listelenir. Tek başına deneyin:
```bash
npx skills@latest add owner/repo@skill -g -a opencode -y
```
En sık neden yanlış skill adıdır — `npx skills@latest add owner/repo -l` ile
repository'deki gerçek adları listeleyin.

**MCP server bağlanmıyor**
`opencode-doctor` ilgili env değişkenini uyarıyor mu? `.env` doldurulduktan
sonra `opencode-sync` çalıştırıp **yeni bir shell açmanız** gerekir — env.sh
ancak o zaman source edilir.

**Config bozuldu**
Her yazma öncesi yedek alınır:
```bash
ls -d ~/.config/opencode.backup-*
cp ~/.config/opencode.backup-<tarih>/opencode.json* ~/.config/opencode/
```

**`opencode.jsonc` içindeki yorumlar kayboldu**
JSONC yorumları yeniden yazma sırasında korunamaz; bootstrap bunu uyarı olarak
bildirir ve yedek alır. Yorum tutmak istiyorsanız yedekten geri alıp
`instructions`/`mcp` alanlarını elle ekleyebilirsiniz.

**Farklı bir config dizini kullanıyorum**
```bash
OPENCODE_CONFIG_DIR=/custom/path ./bootstrap.sh
```

---

## Uninstall

```bash
./uninstall.sh              # config girdileri, alias'lar, kural dosyası
./uninstall.sh --skills     # manifest'teki skill'leri de kaldır
./uninstall.sh --yes        # onay sorma
```

**Kaldırılanlar:** `~/.local/bin` wrapper'ları, `~/.config/opencode/opencode-bootstrap/`,
shell config'indeki managed blok, bu repo'nun eklediği MCP girdileri ve
`instructions` satırı.

**Kaldırılmayanlar:** OpenCode'un kendisi, `auth.json`, provider/model/agent
ayarlarınız, kendi eklediğiniz MCP server'lar, kurulumdan önce var olan hiçbir
config anahtarı. Yedekler de silinmez.

---

## Repository yapısı

```text
opencode-bootstrap/
├── bootstrap.sh              ilk kurulum (profil destekli, idempotent)
├── update.sh                 opencode-sync olarak kurulur
├── doctor.sh                 opencode-doctor olarak kurulur (salt okunur)
├── uninstall.sh              yalnızca bu repo'nun ekledikleri
├── .env.example              secret şablonu — gerçek .env gitignored
├── .gitignore
│
├── config/
│   └── AGENTS.md             global agent kuralları
│
├── skills/
│   ├── frontend.conf         owner/repo|skill-name
│   ├── backend.conf
│   ├── database.conf
│   ├── devops.conf
│   ├── testing.conf
│   ├── security.conf
│   └── profiles.conf         profil → manifest eşlemesi
│
├── mcp/
│   └── mcps.json             OpenCode MCP şemasıyla birebir
│
└── scripts/
    ├── helpers.sh            ortak yardımcılar: renk, yol, backup, .env
    ├── install-skills.sh     manifest → global skill kurulumu
    ├── install-mcps.sh       mcps.json → OpenCode config merge + env.sh
    ├── install-config.sh     AGENTS.md kurulumu + instructions kaydı
    ├── install-aliases.sh    ~/.local/bin wrapper'ları + shell rc bloğu
    └── lib/
        └── merge-config.mjs  cerrahi JSON/JSONC config düzenleyici
```

---

## Tasarım notları

**Neden `AGENTS.md` doğrudan `~/.config/opencode/AGENTS.md`'ye yazılmıyor?**
Orada zaten sizin kişisel kurallarınız olabilir ve OpenCode'da AGENTS.md
precedence tabanlıdır (ilk eşleşen kazanır, birleştirme yapılmaz). Bunun yerine
kurallar `~/.config/opencode/opencode-bootstrap/AGENTS.md` içine yazılır ve
config'in `instructions` alanına kaydedilir — `instructions` dosyaları
AGENTS.md ile **birleştirilir**, bu yüzden her ikisi de geçerli olur.

**Neden config'i düzenlemek için Node kullanılıyor?**
`sed` ile JSON düzenlemek kırılgandır. `scripts/lib/merge-config.mjs` config'i
gerçek bir parser ile okur, yalnızca sahiplendiği anahtarları değiştirir ve geri
yazar. Sahiplik `state.json` içinde tutulur, böylece uninstall tam olarak ne
eklendiyse onu geri alabilir. Ek bir npm bağımlılığı yoktur — sadece Node
standart kütüphanesi.

**Neden `set -Eeuo pipefail` her yerde ama tek bir skill hatası ölümcül değil?**
Kurulum çağrıları ayrıca korunur ve çıktıları yakalanır. Bir upstream
repository bozulduğunda geri kalan ortamın kurulmasını engellememelidir.
Ölümcül sayılanlar yalnızca: eksik `git`/`node`/`npm`/`npx`, eksik `opencode`,
ve config'in yazılamaması.
