# traefik-pocket-id
Traefikはconfigurationが分散してて、自動でいいかんじにプロキシしてくれるやつ。IdP（[Pocket ID](https://pocket-id.org/)）とoauth2-proxyも同居し、アプリのパスをOIDCログインで守れる。
もろもろ実験用。

## setup
1. letsencrypt volumeとPocket IDのdata volumeをマウントするディレクトリを作成
2. DNSをサーバーに向けておく（アプリのホストと`POCKET_ID_HOST`）。IPv6でも受けるならAAAAレコードも追加する。IPv6にはDocker Engine 28以降（`gw_priority`のため）と、daemonの`ip6tables`有効（27以降の既定）が必要
3. .envファイル, basic-adminsファイル, ip-admin.ymlファイルを作成
```bash
cp .env.sample .env
cd config/dynamic
cp .basic-admins.sample .basic-admins
cp ip-admin.yml.sample ip-admin.yml
```
4. 作成したファイルを編集。oauth2-proxyのclient ID/secretは手順8で得るので、ここでは空のままでよい
> [!WARNING]
> ENCRYPTION_KEYはこのホスト以外（パスワードマネージャー等）にも保管すること。失うとPocket IDのバックアップから復元できない。
5. `docker_network_setup.sh`を実行してtraefik_network_*を作成。作成済みのネットワークは飛ばすので、ネットワークが追加されたときは既存ホストでも再実行する
```bash
sudo ./docker_network_setup.sh
```
> [!WARNING]
> traefik_network_*に参加したコンテナへは外部からアクセスされ得る。
> いずれも最低限必要なコンテナのみを参加させるよう十分注意すること。
6. Pocket IDを、`ip-admin`でホスト全体を管理者の送信元IPに制限して起動する。最初の管理者が登録されるまでは、`/setup`を開いた人が誰でも管理者になれるため。oauth2-proxyはまだ起動しないので、client ID/secretには仮の値を渡す
```bash
OAUTH2_PROXY_CLIENT_ID=unset OAUTH2_PROXY_CLIENT_SECRET=unset \
  docker compose -f compose.yaml -f compose.setup.yaml up -d traefik pocket-id
```
7. `https://<POCKET_ID_HOST>/setup`で最初の管理者を登録する
8. Pocket IDの管理画面で以下を作成し、表示されたclient ID/secretを.envに設定する
   - グループ: `admin`。管理者を所属させる。`oidc-admin`はIDトークンの`groups`クレームにこの名前があるかで判定する
   - OIDCクライアント: 名前は`oauth2-proxy`、PKCEを有効、許可するグループは`admin`。Callback URLは`oidc-admin`を付けるアプリのホストごとに`https://<アプリのホスト>/_oauth2/callback`（アプリを追加するたびに足す）
9. 管理者が登録できたことを確認してから、制限を外してすべて起動する
```bash
docker compose up -d
```

## traefik dashboard
dashboardは、sshトンネルでアクセス可能（ホストマシンからdocker network経由でコンテナへアクセス）
```bash
ssh -L 8443:127.0.0.1:8443 host
```
ブラウザで、https://traefik.localhost:8443/dashboard/ にアクセス

> [!NOTE]
> chromeではtraefik.localhostを解決できるが、他ブラウザでは解決できない可能性がある。その場合は、hostsファイルに以下の行を追加する
> ```hosts
> 127.0.0.1 traefik.localhost
> ```

> [!WARNING]
> 8443ポートは外部に公開しないこと

## containerの追加
> [!NOTE]
> `/_oauth2/`は全ホストでoauth2-proxyへ振り分けられる予約パスなので、アプリでは使わないこと。

1. ポートは公開せず、exposeでTraefikに見えるようにする
2. アプリ専用のネットワークを用意する。まだ使われていない番号`N`を選び、このrepoの`.env`に`TRAEFIK_NETWORK_N_CIDR`、`docker_network_setup.sh`と`compose.yaml`に`traefik_network_N`を追加して（`traefik_network_2`のコメントアウトを参考にする）、`docker_network_setup.sh`の実行とTraefikの再起動を行う
3. アプリのcompose.yamlに、traefikのlabelsとネットワークを追加する。ネットワークのキー（`proxy`）は固定し、実際のネットワーク名は.envの`TRAEFIK_NETWORK`で指定する。ホストごとに番号が違っても、compose.yamlを変えずに済むようにするため
```yaml
services:
  ...
  app:
    ...
    labels:
      - "traefik.enable=true"
      # 他のネットワーク（DB等）にも参加している場合に、Traefikがどのネットワーク経由で接続するかを指定する
      - "traefik.docker.network=${TRAEFIK_NETWORK}"
      - "traefik.http.routers.app.rule=Host(`${SUBDOMAIN}${DOMAIN}`)"
      - "traefik.http.routers.app-admin.rule=Host(`${SUBDOMAIN}${DOMAIN}`) && PathPrefix(`/admin`)"
      - "traefik.http.routers.app-admin.middlewares=oidc-admin@file"
    networks:
      - proxy
    expose:
      - 80
    ...
networks:
  proxy:
    # 既定値を付けない。書き忘れたアプリが黙って他のアプリのネットワークにつながるのを防ぐため
    name: ${TRAEFIK_NETWORK:?TRAEFIK_NETWORK is not set}
    external: true
```
```bash
# .env.sample
# Network this app alone joins to be routed by Traefik (traefik_network_N in the traefik repo)
TRAEFIK_NETWORK=
```
4. X-Forwarded-Proto等の転送設定。Traefikからの接続を見分ける必要がある場合（nginxの`set_real_ip_from`等）は、そのネットワークのCIDR（このrepoの.envの`TRAEFIK_NETWORK_N_CIDR`）を指定する

### ネットワークの分離
アプリはそれぞれ専用のネットワーク（`traefik_network_N`）に参加する。アプリ同士はネットワーク上で互いに届かないため、1つのコンテナが乗っ取られても、他のアプリへTraefikを経由せずにアクセスされることはない。

> [!WARNING]
> 1つのネットワークを複数のアプリで共有しないこと。共有したアプリ同士は、Traefikを経由せずに互いに直接リクエストでき、Traefikやその先の認証プロキシが付けるヘッダー（`X-Forwarded-For`、`X-Auth-Request-*`等）を偽装できる。

Pocket ID（`traefik_idp`）、oauth2-proxy（`auth`）、docker-socket-proxy（`socket_proxy`）は、それぞれcompose内のネットワークでTraefikとだけつながっている。アプリをこれらのネットワークに参加させないこと。

### 指定可能なmiddlewareについて
- oidc-admin: Pocket IDでログインし、`admin`グループに所属するユーザーのみ許可する。未ログインならPocket IDのログイン画面へリダイレクトする
- ip-admin: 指定したIPアドレスからのアクセスのみ許可する

`oidc-admin`をアプリに付けるときは、そのホストのCallback URLをPocket IDのOIDCクライアントに追加する。

`ip-admin`と`oidc-admin`の両方を付けると、両方の条件を満たすアクセスだけが許可される。その場合は`middlewares=ip-admin@file,oidc-admin@file`のように`ip-admin`を先に書く。許可していないIPからのアクセスを、ログイン画面へ送る前に拒否するため。

> [!WARNING]
> `oidc-admin`を付けたアプリには、ログインセッションのCookie（`__Host-Http-oauth2_proxy`）がそのまま届く。このCookieはどのホストでも通用するため、乗っ取られたアプリはCookieを別ホストへ送って、そのユーザーの権限で`oidc-admin`の付いた他のアプリにもアクセスできる。アプリはこのCookieを記録したり外部へ送ったりしないこと。

### sshトンネルからのみアクセス可能にする方法
`compose.yaml`のlabelsを以下のようにする。
```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.dashboard.rule=Host(`traefik.localhost`)"
  - "traefik.http.routers.dashboard.entrypoints=internal"
```

## Pocket ID
アプリケーション設定は管理画面ではなく`compose.yaml`の`environment`で管理している（`UI_CONFIG_DISABLED=true`）。設定項目は[公式ドキュメント](https://pocket-id.org/docs/configuration/environment-variables)を参照。

Pocket IDの管理画面と一般ユーザーの画面は同じアプリ・同じ`/api`なので、パスでの制限は効かない。管理者の数を絞って守る。

### パスキーを紛失したとき
1. 管理者が管理画面で該当ユーザーのワンタイムアクセスリンクを発行し、本人に渡す
2. 本人が新しいパスキーを登録する
3. 紛失したパスキーを削除する

管理者全員がログインできなくなった場合は、ホスト上でワンタイムアクセストークンを発行する。
```bash
docker compose exec pocket-id /app/pocket-id one-time-access-token <ユーザー名またはメールアドレス>
```
