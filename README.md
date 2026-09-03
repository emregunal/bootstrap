# ai-dev-bootstrap

Kişisel **AI Development Environment Manager**.

OpenCode, Claude Code ve Codex için skill'leri, MCP server'ları, global agent
kurallarını ve yardımcı komutları tek repository'de tutar; yeni bir makinede
tek komutla kurar, kurulumu doğrular ve bozulduğunda kendi kendini onarır.

```bash
git clone https://github.com/emregunal/bootstrap.git ~/ai-dev-bootstrap
cd ~/ai-dev-bootstrap
./bootstrap.sh
```

WSL Ubuntu ve Linux birincil hedeftir; macOS tam desteklenir. Native Windows
Git Bash platformu tanınır ve temel kurulum/sağlık komutları çalışır; Windows'un
POSIX symlink ve dosya modu sınırlamaları nedeniyle tam davranış için WSL önerilir.

---

## İçindekiler

- [Temel fikir](#temel-fikir)
- [Mimari](#mimari)
- [Repository yapısı](#repository-yapısı)
- [Yeni bilgisayarda kurulum (adım adım)](#yeni-bilgisayarda-kurulum-adım-adım)
- [Yeni bir projede kullanım](#yeni-bir-projede-kullanım)
- [Global komutlar](#global-komutlar)
- [Script'ler: görev, çağrı grafiği, read-only / değiştiren](#scriptler)
- [Adapter sistemi](#adapter-sistemi)
- [Skill yönetimi](#skill-yönetimi)
- [MCP yönetimi](#mcp-yönetimi)
- [Global rules](#global-rules)
- [Secret güvenliği](#secret-güvenliği)
- [Git hooks](#git-hooks)
- [Commit ve push workflow'u](#commit-ve-push-workflowu)
- [Self-healing: neyi onarır, neyi onarmaz](#self-healing)
- [Dry-run ve verbose](#dry-run-ve-verbose)
- [Exit code standardı](#exit-code-standardı)
- [Test etme](#test-etme)
- [CI](#ci)
- [Sorun giderme](#sorun-giderme)
- [Kaldırma](#kaldırma)

---

## Temel fikir

```
GitHub repository  =  istenen konfigürasyon (desired state)
Lokal makine       =  çalışma zamanı durumu + credential'lar
```

GitHub şunları bilir: hangi skill'ler kurulacak, hangi MCP server'lar tanımlı,
hangi kurallar geçerli, hangi config beklenir.

GitHub şunları **asla** bilmez: API key'ler, OAuth token'ları, private SSH
key'ler, veritabanı şifreleri, session credential'ları.

Bu ayrım repository'nin tamamını yöneten tek kuraldır. `preflight.sh`,
`.gitignore`, `.githooks/pre-commit` ve CI'daki secret job'ı bu kuralı
mekanik olarak zorlar — iyi niyete bırakılmaz.

---

## Mimari

```
                        GitHub
                   ai-dev-bootstrap
                          │
              ┌───────────┼───────────┐
              │           │           │
           Skills        MCP        Rules
        skills/*.conf  mcps.json  rules/global.md
              │           │           │
              └───────────┼───────────┘
                          │
                      Adapters
              adapters/<agent>/adapter.sh
              ┌───────────┼───────────┐
              ▼           ▼           ▼
          OpenCode   Claude Code    Codex
              │           │           │
              └───────────┼───────────┘
                          │
                    Lokal makine
                          │
        ┌─────────────────┼─────────────────┐
        ▼                 ▼                 ▼
     check.sh         verify.sh         audit.sh
     (onarır)        (sadece bakar)   (derin denetim)
                          │
                     self-healing
```

Her agent'ın nasıl yapılandırılacağı bilgisi **yalnızca** kendi adapter'ında
durur. Yeni bir agent eklemek `adapters/<isim>/adapter.sh` yazmaktır; başka
hiçbir dosya değişmez.

---

## Repository yapısı

```text
ai-dev-bootstrap/
├── bootstrap.sh              # kurulum (scripts/setup/setup.sh'a exec eder)
├── update.sh                 # ai-dev-sync
├── doctor.sh                 # ai-dev-doctor
├── uninstall.sh              # kurulanları geri alır
├── .env.example              # secret şablonu (gerçek .env asla commit edilmez)
├── .gitattributes            # Windows checkout'larında metin dosyalarını LF tutar
├── .gitignore
│
├── rules/
│   └── global.md             # tüm agent'lara dağıtılan tek kural dosyası
│
├── skills/
│   ├── profiles.conf         # profil → manifest eşlemesi
│   ├── frontend.conf
│   ├── backend.conf
│   ├── database.conf
│   ├── devops.conf
│   ├── testing.conf
│   └── security.conf
│
├── mcp/
│   └── mcps.json             # MCP server manifest'i (tek kaynak)
│
├── config/
│   ├── shared/               # her agent'a symlink'lenir
│   ├── opencode/             # sadece OpenCode'a
│   ├── claude/               # sadece Claude Code'a
│   └── codex/                # sadece Codex'e
│
├── adapters/
│   ├── opencode/adapter.sh
│   ├── claude-code/adapter.sh
│   └── codex/adapter.sh
│
├── scripts/
│   ├── lib/
│   │   ├── common.sh              # yollar, exit code'lar, symlink/blok primitifleri
│   │   ├── logging.sh             # tüm çıktı buradan geçer
│   │   ├── platform.sh            # Linux / WSL / macOS / Windows farkları
│   │   ├── merge-config.mjs       # OpenCode config'ini cerrahi düzenler
│   │   ├── mcp-render.mjs         # manifest → agent lehçesi çevirisi
│   │   └── secret-patterns.conf   # secret tarama pattern'leri
│   │
│   ├── setup/
│   │   ├── setup.sh               # ana orkestratör
│   │   ├── check.sh               # sağlık kontrolü + self-heal (ai-dev-check)
│   │   ├── install-adapters.sh    # rules + config fragment'ları
│   │   ├── install-commands.sh    # ~/.local/bin wrapper'ları + PATH
│   │   ├── install-hooks.sh       # core.hooksPath
│   │   ├── install-skills.sh      # skill kurulumu
│   │   ├── install-mcps.sh        # credential bridge + MCP
│   │   └── install-ssh.sh         # SSH/GitHub yardımcısı
│   │
│   ├── git/
│   │   ├── preflight.sh           # commit/push güvenlik kapısı
│   │   └── commit.sh              # güvenli commit workflow'u
│   │
│   └── context/
│       ├── verify.sh              # drift tespiti (ai-dev-verify)
│       ├── audit.sh               # derin denetim (ai-dev-audit)
│       ├── behavior-check.sh      # davranış testleri
│       └── detect-local-install.sh# kurulum yerini tespit
│
├── .githooks/
│   ├── pre-commit
│   └── commit-msg
│
├── .github/workflows/
│   └── validate.yml
│
└── state/                    # makineye özel çıktı — .gitignore'da
    └── .gitkeep
```

---

## Yeni bilgisayarda kurulum (adım adım)

### 1. Sistem bağımlılıkları

**WSL Ubuntu / Debian / Ubuntu:**

```bash
sudo apt update
sudo apt install -y git curl build-essential

# Node.js LTS
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install -y nodejs

# doğrula
git --version && node --version && npm --version && npx --version
```

**macOS:**

```bash
xcode-select --install          # git için (zaten varsa atlar)
brew install node
```

Gerekli olanlar: `git`, `node`, `npm`, `npx`. Bunlar yoksa `bootstrap.sh`
exit code **3** ile durur ve tam kurulum komutunu yazdırır.

### 2. En az bir AI agent kur

Üçü de zorunlu değildir; **en az biri** olmalıdır. Kurulu olmayan agent
sessizce atlanır.

```bash
# OpenCode
curl -fsSL https://opencode.ai/install | bash

# Claude Code
curl -fsSL https://claude.ai/install.sh | bash

# Codex
npm install -g @openai/codex
```

Doğrula:

```bash
opencode --version ; claude --version ; codex --version
```

### 3. Repository'yi klonla

```bash
git clone https://github.com/emregunal/bootstrap.git ~/ai-dev-bootstrap
cd ~/ai-dev-bootstrap
```

> Dizin adı ve konumu serbesttir. Hiçbir script yol hard-code etmez; her şey
> `scripts/lib/common.sh` içindeki symlink-çözen tespitten türetilir. Repo'yu
> sonradan taşırsanız `ai-dev-check` bunu fark eder ve wrapper'ları onarır.

### 4. Secret'ları hazırla (opsiyonel ama önerilir)

`.env` **repository'de değildir** ve asla olmayacaktır. Her makinede elle
oluşturulur:

```bash
cp .env.example .env
chmod 600 .env
$EDITOR .env
```

| Değişken | Zorunlu mu | Ne işe yarar |
|---|---|---|
| `CONTEXT7_API_KEY` | hayır | Context7 rate limit'ini yükseltir; anahtarsız da çalışır |
| `GITHUB_TOKEN` | GitHub MCP için evet | Yoksa server `enabled: false` yazılır, hata vermez |
| `MCP_FILESYSTEM_ROOT` | hayır | Filesystem MCP'nin kök dizini (varsayılan `$HOME`) |

`.env` olmadan da kurulum tamamlanır. Anahtar isteyen server'lar yapılandırılır
ama kimlik doğrulaması yapamaz; `ai-dev-doctor` bunu **uyarı** olarak gösterir,
hata olarak değil.

### 5. Önce dene, sonra kur

Hiçbir şeyi değiştirmeden ne olacağını gör:

```bash
./bootstrap.sh --dry-run
```

Çıktı `WOULD CREATE`, `WOULD LINK`, `WOULD INSTALL`, `WOULD CONFIGURE`
satırlarından oluşur. Bu modda tek bir dosya bile yazılmaz — bu davranış
`behavior-check.sh` içinde snapshot karşılaştırmasıyla test edilir.

Sonra gerçekten kur:

```bash
./bootstrap.sh
```

Sadece belirli bir profil istiyorsanız:

```bash
./bootstrap.sh --profile frontend
```

### 6. Shell'i yenile

```bash
exec $SHELL -l
# veya
source ~/.bashrc     # zsh kullanıyorsanız ~/.zshrc
```

Bu adım gereklidir: `~/.local/bin` PATH'e ve credential bridge
(`~/.config/ai-dev-bootstrap/env.sh`) shell ortamına bu sırada girer.

### 7. Doğrula

```bash
ai-dev-doctor
```

Beklenen son satır: `✓ Everything checks out`.

Daha derin kontrol:

```bash
ai-dev-doctor --full     # check + verify + audit + davranış testleri
```

### 8. (Opsiyonel) SSH ve GitHub

```bash
./scripts/setup/install-ssh.sh
```

Bu script **hiçbir zaman private key üretmez veya değiştirmez**. `~/.ssh`
varlığını, izinleri, mevcut public key'leri, `known_hosts` durumunu ve GitHub
bağlantısını kontrol eder. Key üretmek isterseniz komutu size yazdırır:

```bash
ssh-keygen -t ed25519 -C "you@example.com"
cat ~/.ssh/id_ed25519.pub          # https://github.com/settings/keys adresine ekle
```

İzinleri düzeltmek ve `~/.ssh` oluşturmak için açık bayrak gerekir:

```bash
./scripts/setup/install-ssh.sh --fix-perms --add-host
```

### Tek blok halinde tüm kurulum

```bash
# 1. bağımlılıklar (yukarıdaki 1. ve 2. adım)
# 2. repo
git clone https://github.com/emregunal/bootstrap.git ~/ai-dev-bootstrap
cd ~/ai-dev-bootstrap

# 3. secret'lar
cp .env.example .env && chmod 600 .env && $EDITOR .env

# 4. önizleme + kurulum
./bootstrap.sh --dry-run
./bootstrap.sh

# 5. shell
exec $SHELL -l

# 6. doğrulama
ai-dev-doctor
```

---

## Yeni bir projede kullanım

Bu repository **makine seviyesinde** çalışır. Kurulumdan sonra açtığınız her
proje, hiçbir ek adım gerektirmeden şunları devralır:

- `rules/global.md` içindeki kurallar (üç agent'ta da geçerli)
- kurulu skill'ler (`~/.agents/skills` altında, agent dizinlerine symlink)
- tanımlı MCP server'lar

Yeni bir projeye başlarken:

```bash
mkdir ~/dev/yeni-proje && cd ~/dev/yeni-proje
git init

# agent'ı başlat — global kurallar ve skill'ler otomatik yüklü
opencode      # veya: claude / codex
```

**Proje bazlı ekleme yapmak isterseniz:** global kurallar temel varsayılandır,
projenin kendi `AGENTS.md` / `CLAUDE.md` dosyası önceliklidir. Yani proje
kökünde bir `AGENTS.md` oluşturmanız global kuralları ezmez, üstüne biner.

**Bu repository'nin güvenlik araçlarını başka bir projede kullanmak
isterseniz** iki yol var:

```bash
# 1) Doğrudan çağır (kendi repo'sunu tarar, bu yüzden o repo içinden çalıştırın)
cd ~/dev/yeni-proje
~/ai-dev-bootstrap/scripts/git/preflight.sh --secrets-only

# 2) O projenin hook'u olarak kur
cd ~/dev/yeni-proje
mkdir -p .githooks
cat > .githooks/pre-commit <<'EOF'
#!/usr/bin/env bash
exec ~/ai-dev-bootstrap/scripts/git/preflight.sh --staged
EOF
chmod +x .githooks/pre-commit
git config core.hooksPath .githooks
```

> Not: `preflight.sh` kendi repository kökünü `common.sh` üzerinden çözer ve
> oraya `cd` eder. Başka bir projeyi taramak için o projeye kopyalayın veya
> yukarıdaki gibi ince bir wrapper yazın.

---

## Global komutlar

Kurulumdan sonra `~/.local/bin` altına beş komut gelir. Bunlar symlink değil,
**wrapper**'dır: repository yolunu içlerinde saklarlar, böylece hangi dizinden
çağırırsanız çağırın çalışırlar ve repo taşınırsa anlaşılır bir hata verirler
(`ai-dev-check` bunu otomatik onarır).

| Komut | Ne yapar | Sistemi değiştirir mi |
|---|---|---|
| `ai-dev-doctor` | Tam sağlık raporu (check + verify) | **hayır** |
| `ai-dev-doctor --full` | + audit + davranış testleri | **hayır** |
| `ai-dev-check` | Kontrol eder ve güvenli olanları onarır | **evet** (sadece kendi dosyaları) |
| `ai-dev-verify` | Repo ile makine arasındaki drift'i raporlar | **hayır** |
| `ai-dev-audit` | Derin denetim + `state/audit-last.txt` raporu | **hayır** |
| `ai-dev-sync` | Repo'yu çeker ve her şeyi yeniden uygular | **evet** |

---

## Script'ler

### Her `.sh` dosyasının görevi

| Dosya | Görev | Read-only? |
|---|---|---|
| `bootstrap.sh` | Giriş noktası; `setup.sh`'a `exec` eder | değiştirir |
| `update.sh` | `git pull --ff-only` + tüm kurulumu yeniden uygular | değiştirir |
| `doctor.sh` | check + verify (+ `--full` ile audit + testler) | **read-only** |
| `uninstall.sh` | Kurulan her şeyi geri alır | değiştirir |
| `scripts/setup/setup.sh` | 8 adımlık kurulum orkestrasyonu | değiştirir |
| `scripts/setup/check.sh` | Sağlık kontrolü + güvenli self-heal | değiştirir (onarım) |
| `scripts/setup/install-adapters.sh` | Her agent'a rules + config fragment | değiştirir |
| `scripts/setup/install-commands.sh` | `~/.local/bin` wrapper'ları + rc bloğu | değiştirir |
| `scripts/setup/install-hooks.sh` | `git config core.hooksPath .githooks` | değiştirir |
| `scripts/setup/install-skills.sh` | `skills` CLI ile skill kurulumu | değiştirir |
| `scripts/setup/install-mcps.sh` | Credential bridge + adapter'lara MCP | değiştirir |
| `scripts/setup/install-ssh.sh` | SSH durumu; bayraksız sadece rapor | **read-only** (bayraksız) |
| `scripts/git/preflight.sh` | Güvenlik kapısı: secret, conflict, syntax | **read-only** |
| `scripts/git/commit.sh` | preflight → commit → (opsiyonel) push | değiştirir (git) |
| `scripts/context/verify.sh` | Drift tespiti | **read-only** |
| `scripts/context/audit.sh` | Derin denetim + rapor dosyası | **read-only** (+rapor) |
| `scripts/context/behavior-check.sh` | Davranış testleri | **read-only** (`--mutate` hariç) |
| `scripts/context/detect-local-install.sh` | Repo kökü ve kurulum yerini çözer | **read-only** |
| `scripts/lib/common.sh` | Yollar, exit code'lar, symlink/blok primitifleri | sourced |
| `scripts/lib/logging.sh` | `info/success/warn/error/die/section` + redaction | sourced |
| `scripts/lib/platform.sh` | `readlink -f`, `sed -i`, `stat`, `sha256sum` sarmalayıcıları | sourced |
| `adapters/*/adapter.sh` | Agent'a özel kurulum/doğrulama | değiştirir (`apply`) |
| `.githooks/pre-commit` | `preflight.sh --staged` çalıştırır | **read-only** |
| `.githooks/commit-msg` | Commit mesajı kalite kontrolü | **read-only** |

### Çağrı grafiği

```
bootstrap.sh
   └── scripts/setup/setup.sh
         ├── install-adapters.sh ──► adapters/*/adapter.sh apply
         ├── install-commands.sh
         ├── install-hooks.sh
         ├── install-skills.sh
         ├── install-mcps.sh ──────► adapters/*/adapter.sh mcp-apply
         └── check.sh

update.sh (ai-dev-sync)
   ├── git pull --ff-only
   ├── install-adapters.sh
   ├── install-commands.sh
   ├── install-hooks.sh
   ├── install-skills.sh
   ├── install-mcps.sh
   ├── verify.sh
   └── check.sh

doctor.sh (ai-dev-doctor)
   ├── check.sh --no-repair
   ├── verify.sh
   └── --full ise: audit.sh + behavior-check.sh

commit.sh
   └── preflight.sh --staged
         ├── merge conflict taraması
         ├── secret taraması
         ├── shell syntax (bash -n)
         └── JSON doğrulama

audit.sh
   ├── verify.sh --quiet
   ├── preflight.sh --secrets-only
   ├── symlink sweep
   ├── permissions
   └── manifest doğrulama

check.sh
   └── adapters/*/adapter.sh plan   (onarılacak symlink listesi)
```

Circular dependency yoktur. `scripts/lib/*` hiçbir şey çağırmaz; adapter'lar
yalnızca `lib`'e bağlıdır; orkestratörler adapter'lara ve `lib`'e bağlıdır.

### Read-only olanlar

`doctor.sh`, `verify.sh`, `preflight.sh`, `detect-local-install.sh`,
`behavior-check.sh` (varsayılan), `install-ssh.sh` (bayraksız),
`check.sh --no-repair`, `audit.sh` (yalnızca `state/audit-last.txt` yazar).

### Sistemi değiştirenler

`bootstrap.sh`, `setup.sh`, `update.sh`, `install-*.sh`, `check.sh`
(varsayılan, onarım modu), `commit.sh`, `uninstall.sh`,
`adapter.sh apply|mcp-apply|remove`, `behavior-check.sh --mutate`
(yalnızca geçici `HOME` içinde).

---

## Adapter sistemi

Her adapter aynı sekiz alt komutu uygular:

| Alt komut | Ne döner |
|---|---|
| `label` | İnsan okunur isim |
| `detect` | Agent kurulu mu (exit 0/1) |
| `paths` | `KEY=VALUE` satırları |
| `plan` | `LINK\|src\|dest\|açıklama` / `BLOCK\|dosya\|açıklama` |
| `apply` | Rules + config fragment'larını kurar |
| `mcp-apply` | MCP server'larını kurar |
| `verify` | `OK\|MISS\|DRIFT\|WARN\|SKIP` satırları, drift varsa exit 5 |
| `remove` | Kurduklarını geri alır |

`plan` çıktısı deklaratiftir: `check.sh` bu listeyi okuyup bozuk symlink'leri
onarır, `verify.sh` aynı listeyi okuyup rapor eder, `uninstall.sh` aynı
listeyi okuyup temizler. Tek kaynak, üç tüketici.

### Agent'lara ne yazılır

| Agent | Rules | MCP |
|---|---|---|
| **OpenCode** | `~/.config/opencode/ai-dev-bootstrap/global.md` (symlink) + config'in `instructions` dizisine kayıt | `mcp` bloğuna merge; secret'lar `{env:VAR}` olarak **runtime'da** çözülür |
| **Claude Code** | `~/.claude/rules/ai-dev-global.md` (symlink) — dosya düzenlenmez, link'in kendisi entegrasyon noktasıdır | `claude mcp add-json -s user` ile; `~/.claude.json` dosyasına elle dokunulmaz |
| **Codex** | `~/.codex/AGENTS.md` içinde işaretli blok (Codex include desteklemez) | `~/.codex/config.toml` içinde işaretli `[mcp_servers.*]` bloğu; yazımdan sonra TOML doğrulanır, bozuksa **geri alınır** |

### Yeni agent ekleme

```bash
mkdir -p adapters/yeni-agent
cp adapters/claude-code/adapter.sh adapters/yeni-agent/adapter.sh
$EDITOR adapters/yeni-agent/adapter.sh
```

Başka hiçbir dosyayı değiştirmeniz gerekmez — `adapter_list()` dizini tarar.

---

## Skill yönetimi

Format: `owner/repo|skill-adı`

```conf
# skills/frontend.conf
anthropics/skills|frontend-design
vercel-labs/agent-skills|vercel-react-best-practices
```

`skill-adı`, skill'in `SKILL.md` dosyasındaki `name:` alanıyla eşleşmelidir;
bu her zaman klasör adıyla aynı değildir.

Profiller `skills/profiles.conf` içinde:

```conf
frontend|frontend
backend|backend,database
full|frontend,backend,database,devops,testing,security
```

```bash
./bootstrap.sh --profile backend      # backend + database
ai-dev-sync --profile frontend
ai-dev-sync --refresh-skills          # kurulu olanları da yeniden indir
```

Skill'ler `~/.agents/skills` altında bir kez tutulur; `skills` CLI bunları her
agent'ın kendi dizinine symlink'ler. Bu yüzden tek kurulum üç agent'ı da
kapsar. Bozulan symlink'leri `ai-dev-check` raporlar.

---

## MCP yönetimi

Tek manifest: `mcp/mcps.json`. OpenCode şemasıyla yazılır (üçünün en
zengini); `scripts/lib/mcp-render.mjs` diğer lehçelere çevirir.

```json
{
  "servers": {
    "context7": {
      "optionalEnv": ["CONTEXT7_API_KEY"],
      "config": {
        "type": "remote",
        "url": "https://mcp.context7.com/mcp",
        "enabled": true,
        "headers": { "Authorization": "Bearer {env:CONTEXT7_API_KEY}" }
      }
    }
  }
}
```

**İki placeholder türü:**

| Placeholder | Ne zaman çözülür | Ne için |
|---|---|---|
| `{env:VAR}` | OpenCode tarafından **runtime'da** | Secret'lar — değer hiçbir config dosyasına yazılmaz |
| `{install:VAR}` | Kurulum sırasında | Makineye özel yollar, portlar |

**İki metadata alanı:**

- `requiresEnv` — bu değişken yoksa server çalışamaz. OpenCode'da
  `enabled: false` yazılır; Claude Code ve Codex'te server hiç eklenmez.
  Anahtarı verip `ai-dev-sync` çalıştırınca etkinleşir.
- `optionalEnv` — server anahtarsız da çalışır (anonim / düşük rate limit).
  Asla devre dışı bırakılmaz, yalnızca uyarı verilir.

Eksik anahtar **hata değildir**; kurulum tamamlanır.

Yeni server eklemek için `servers` altına bir kayıt ekleyin — başka hiçbir yer
değişmez.

---

## Global rules

`rules/global.md` tek kaynaktır ve üç agent'a da aynı içerik gider.
Düzenlemesi gereken dosya budur; agent dizinlerindeki kopyalar üretilmiştir.

```bash
$EDITOR rules/global.md
ai-dev-sync
```

OpenCode ve Claude Code'da symlink kullanıldığı için dosyayı kaydettiğiniz an
etkilidir. Codex'te blok yeniden render edilir; `ai-dev-check` içerik
farkını görüp bloğu tazeler (bu onarım risksizdir, çünkü yalnızca kendi
yazdığı işaretli bölgeye dokunur).

`config/shared/` ve `config/<agent>/` dizinlerine ek dosya bırakarak agent
başına ek içerik dağıtabilirsiniz; ayrıntı için `config/README.md`.

---

## Secret güvenliği

Beş katman:

**1. `.gitignore`** — `.env`, `*.pem`, `*.key`, `id_rsa`, `id_ed25519`,
`credentials.json`, `secrets.json`, `auth.json`, `.netrc` ve tüm backup
dosyaları.

**2. Secret tarayıcı** (`scripts/lib/secret-patterns.conf`) — GitHub PAT'leri,
OpenAI/Anthropic tarzı anahtarlar, Google API key, Slack token, AWS access
key, Context7 key, private key blokları, literal Bearer token'ları,
değer taşıyan credential atamaları, gömülü kimlikli connection string'ler.

Pattern'ler credential'ın **şeklini** arar, ön ekini değil: düz metindeki
`sk-` bulgu değildir, yirmi anahtar karakteri izleyen `sk-` bulgudur. Eşleşen
metin ayrıca placeholder allowlist'inden geçirilir — `{env:VAR}`, `$VAR`,
`<your-token>`, `.env.example`'daki boş atamalar asla bulgu üretmez.

> Bulgu raporlanırken **değer asla yazdırılmaz**; yalnızca `dosya:satır` ve
> pattern adı gösterilir. `--verbose` dahil hiçbir mod secret basmaz.

**3. Tehlikeli dosya kontrolü** — staged ve tracked dosyalar isim bazlı
taranır; `.env` gibi bir dosya git'e girmişse `git rm --cached` önerisiyle
raporlanır.

**4. Credential bridge** — `.env` içindeki değerler
`~/.config/ai-dev-bootstrap/env.sh` dosyasına **mode 600** ile yazılır ve
login shell tarafından source edilir. Böylece OpenCode `{env:VAR}`'ı kendi
process ortamından çözer; anahtar hiçbir config dosyasına yazılmaz.

> Claude Code ve Codex'in user-scope MCP tanımlarında runtime placeholder
> desteği yoktur. Bu iki agent için anahtar kurulum anında çözülür ve
> **lokal** config dosyasına yazılır. Script bunu açıkça uyarır ve
> `config.toml`'u 600'de tutar. Bu dosyalar repository'ye asla girmez.

**5. Git hooks + CI** — her commit'te `preflight.sh --staged`, her push'ta
CI'da `preflight.sh --secrets-only` ve tracked credential dosyası kontrolü.

---

## Git hooks

`.git/hooks` commit edilemez, bu yüzden hook'lar `.githooks/` altında
versiyonlanır ve git oraya yönlendirilir:

```bash
git config core.hooksPath .githooks
```

Bu satırı `scripts/setup/install-hooks.sh` çalıştırır; `bootstrap.sh` ve
`ai-dev-sync` otomatik yapar, `ai-dev-check` bozulursa geri koyar.

Yol **göreli** verilir; git bunu working tree kökünden çözer, böylece repo
taşınsa da ayar bozulmaz.

### pre-commit

`preflight.sh --staged` çalıştırır: yalnızca staged içerik, ağ erişimi yok,
ağır bütünlük taraması yok. Kritik bulguda commit engellenir.

### commit-msg

Conventional Commit kontrolü yapar: `feat fix docs style refactor perf test
build ci chore revert`. Merge/revert/fixup mesajları muaftır. Uzun subject
uyarı üretir ama engellemez.

Kapatmak için:

```bash
git config ai-dev.commitMessageCheck false     # kalıcı
COMMIT_MESSAGE_CHECK=false git commit -m "..."  # tek seferlik
```

Acil durumda tüm hook'ları atlamak: `git commit --no-verify`.

---

## Commit ve push workflow'u

```bash
git add <istediğiniz-dosyalar>
./scripts/git/commit.sh "feat: add backend skills"
```

Akış: staged kontrolü → preflight → commit → log.

- `git add .` **asla** çalıştırılmaz; ne stage edeceğinize siz karar verirsiniz.
- Staged değişiklik yoksa `Nothing staged for commit.` der ve durur.
- Preflight'ta secret bulunursa commit yapılmaz, exit **4**.

Push:

```bash
./scripts/git/commit.sh "feat: ..." --push
```

`--push` verilirse commit'ten sonra **tam** preflight tekrar çalışır (staged
değil, tüm tracked dosyalar). Temiz değilse push yapılmaz.

---

## Self-healing

`ai-dev-check` yalnızca **risksiz** onarımları yapar:

| Onarır | Onarmaz |
|---|---|
| Eksik/bozuk/yanlış hedefli symlink (kendi sahip olduğu) | Gerçek dosya duran bir yol — sadece uyarır |
| Silinmiş `~/.local/bin` wrapper'ı | Kullanıcının kendi yazdığı wrapper |
| Başka bir klona işaret eden wrapper | Kullanıcı config'i veya credential'ları |
| `core.hooksPath` ayarı | Kullanıcının eklediği MCP server'ları |
| Executable biti düşmüş kendi script'i | `.env` veya `auth.json` |
| Kendi managed dizinindeki ölü symlink | Managed dizin dışındaki ölü symlink (raporlar) |
| Eksik kendi dizinleri | Agent'ların kendi dosyaları |

Onarım yapmadan görmek için:

```bash
ai-dev-check --no-repair     # sadece rapor
ai-dev-check --dry-run       # ne onaracağını göster
```

---

## Dry-run ve verbose

`--dry-run` destekleyen her script hiçbir dosyaya dokunmaz:

```bash
./bootstrap.sh --dry-run
./update.sh --dry-run
./scripts/setup/check.sh --dry-run
./uninstall.sh --dry-run
```

Bu davranış test edilir: `behavior-check.sh` geçici bir `HOME` oluşturur,
öncesi/sonrası dosya listesini karşılaştırır ve tek bir fark bulursa test
başarısız olur.

Verbose:

```bash
./bootstrap.sh --verbose
DEBUG=1 ai-dev-check
```

Verbose modda bile secret değerleri yazdırılmaz.

---

## Exit code standardı

| Kod | Anlamı |
|---|---|
| 0 | Başarılı |
| 1 | Genel hata |
| 2 | Config problemi (parse edilemeyen dosya, eksik yapı) |
| 3 | Eksik dependency |
| 4 | Security / preflight problemi |
| 5 | Drift bulundu |

CI ve git hook'ları bu kodlara göre dallanır. Örnek:

```bash
ai-dev-verify
case $? in
  0) echo "senkron" ;;
  5) ai-dev-sync ;;
  *) echo "inceleme gerekli" ;;
esac
```

---

## Test etme

```bash
./scripts/context/behavior-check.sh            # read-only davranış testleri
./scripts/context/behavior-check.sh --mutate   # + geçici HOME'da tam kurulum
./doctor.sh --full                             # her şey
```

`--mutate` testleri gerçek installer'ları çalıştırır ama **atılabilir bir
`HOME` dizinine** karşı: gerçek ev dizininizin dokunulmadığı testlerden biri
olarak ayrıca doğrulanır. Test edilenler arasında symlink primitifleri, blok
idempotency'si, adapter sözleşmeleri, MCP render çıktılarının geçerliliği,
secret tarayıcının hem yakalaması hem yanlış pozitif üretmemesi, hook'ların
gerçek bir commit'i engellemesi, exit code'lar, dry-run'ların hiçbir şey
değiştirmemesi, kurulumun idempotent olması ve bilerek bozulan bir link'in
onarılması var.

Shell syntax ve lint:

```bash
find . -name '*.sh' -not -path './.git/*' -exec bash -n {} \;
shellcheck -x -S warning $(find . -name '*.sh' -not -path './.git/*') .githooks/*
```

ShellCheck kurulu değilse hiçbir şey engellenmez.

---

## CI

`.github/workflows/validate.yml` beş job çalıştırır:

| Job | Ne kontrol eder |
|---|---|
| `shell` | `bash -n`, ShellCheck (warning seviyesi), her script'in `--help`'i |
| `manifests` | JSON/YAML parse, skill manifest formatı, profil bütünlüğü, MCP render'ının her hedef için geçerliliği |
| `security` | Tracked dosyalarda secret taraması, credential dosyası kontrolü |
| `behaviour` | Davranış testleri (read-only) + dry-run'ın `HOME`'u değiştirmediği |
| `macos` | Aynı testler macOS'ta (bash 3.2 + BSD userland uyumluluğu) |

CI hiçbir credential istemez ve gerçek bir kullanıcı home dizinini değiştirmez.

---

## Sorun giderme

**`ai-dev-doctor: command not found`**

```bash
exec $SHELL -l          # PATH henüz yenilenmemiş
echo $PATH | tr ':' '\n' | grep '.local/bin'
```

**Repo'yu taşıdım, komutlar bozuldu**

```bash
cd /yeni/konum/ai-dev-bootstrap
./bootstrap.sh          # wrapper'ları yeni yola göre yazar
# veya sadece:
./scripts/setup/check.sh
```

**`ai-dev-verify` drift gösteriyor**

```bash
ai-dev-verify           # neyin drift ettiğini gösterir
ai-dev-sync             # repo durumunu makineye uygular
```

**MCP server "disabled" yazıyor**

`requiresEnv` değişkeni eksiktir:

```bash
grep GITHUB_TOKEN .env  # boş mu?
$EDITOR .env
ai-dev-sync
```

**Commit engelleniyor ama secret yok (yanlış pozitif)**

```bash
./scripts/git/preflight.sh --staged     # hangi dosya:satır olduğunu gösterir
```

Gerçekten yanlış pozitifse ya değeri placeholder haline getirin
(`<your-token>`, `{env:VAR}`) ya da `scripts/lib/secret-patterns.conf`
içindeki pattern'i daraltın. Son çare: `git commit --no-verify`.

**Codex config.toml bozuldu**

Yazımdan sonra TOML doğrulanır ve bozuksa otomatik geri alınır. Yine de elle
dönmek isterseniz:

```bash
ls ~/.codex/config.toml.ai-dev-backup-*
cp ~/.codex/config.toml.ai-dev-backup-<tarih> ~/.codex/config.toml
```

**OpenCode config'i bozuldu**

```bash
ls -d ~/.config/opencode.backup-*
cp ~/.config/opencode.backup-<tarih>/opencode.json ~/.config/opencode/
```

İlk yazma işleminden önce her zaman yedek alınır; son 10 yedek tutulur.

---

## Kaldırma

```bash
./uninstall.sh --dry-run     # önce ne silineceğini gör
./uninstall.sh               # config, komutlar, rules, hook ayarı
./uninstall.sh --skills      # + manifest'teki skill'ler
```

Silinenler: `~/.local/bin/ai-dev-*` wrapper'ları, her agent'ın managed
dizini, bu repo'nun eklediği MCP kayıtları ve rules registration'ları, shell
rc bloğu, credential bridge, `core.hooksPath` ayarı.

Korunanlar: agent'ların kendisi, credential'larınız, provider/model/agent
ayarlarınız, kendi eklediğiniz MCP server'lar ve bu repo'nun hiç yazmadığı
her config anahtarı.
