# gcp-spend-cap

English: [README.md](README.md)

`gcp-spend-cap.sh` は、Cloud Billing の **費用上限予算（Spend Cap Budget）** をコマンドラインから管理するスクリプトです。1 つのプロジェクト内の特定サービスについて、月間の推定利用額が設定した金額に達した時点で新規のリクエスト利用を自動的に一時停止します。

| キー | 対象サービス |
| --- | --- |
| `gemini` | Gemini API |
| `vertex` | Gemini platform（旧 Vertex AI） |
| `run` | Cloud Run |
| `functions` | Cloud Run functions |

## 必要な環境

スクリプトの動作には次のツールと設定が必要です。

- bash 3.2 以降、`curl`、`jq`（macOS 15 以降や Cloud Shell には標準で含まれています。Linux で `jq` が未導入の場合は `sudo apt install jq` でインストールしてください）。
- ログイン済みの gcloud CLI。現在有効な gcloud 構成（`gcloud auth login`）の認証情報を使用し、ユーザー トークンの再認証が必要な場合は Application Default Credentials (ADC) にフォールバックします。別の gcloud 構成を使う場合は、`CLOUDSDK_CONFIG=~/.config/gcloud-other ./gcp-spend-cap.sh ...` のように環境変数を前置して呼び出します。
- 対象プロジェクトでの `billingbudgets.googleapis.com` と `cloudbilling.googleapis.com` の有効化。初回のみ `--enable-api` を付けて呼び出してください。

## 使い方

対象プロジェクトに対して初めてコマンドを実行するときは、`status` で状態を確認する場合も含め、必要な API（`billingbudgets.googleapis.com` と `cloudbilling.googleapis.com`）を有効化するために必ず **`--enable-api`** を付けてください。一度有効化すれば 2 回目以降は不要です。

```bash
# 対象プロジェクトへの初回実行時（statusの確認でも初回は--enable-apiが必要）
./gcp-spend-cap.sh status -p my-project --enable-api

# 4つの対象サービスすべてに月額10,000の上限を設定（API未有効なら--enable-apiを追加）
./gcp-spend-cap.sh set -p my-project -a 10000

# Gemini APIとGemini platformのみを対象にし、変更内容を事前プレビュー
./gcp-spend-cap.sh set -p my-project -a 5000 -s gemini,vertex --dry-run

# 現在の上限額とステータスを表示（2回目以降は--enable-api不要）
./gcp-spend-cap.sh status -p my-project

# 上限到達により一時停止されたサービスの利用を再開
./gcp-spend-cap.sh lift -p my-project

# 確認プロンプトなしで上限設定を削除
./gcp-spend-cap.sh delete -p my-project --yes
```

すべてのサブコマンドで、`-p`（対象プロジェクト、省略時は現在の gcloud 設定のプロジェクト）、`-s`（対象サービス、`all` またはカンマ区切り）、`-y`（確認プロンプトの省略）、`--dry-run`、`--enable-api` を指定できます。`set` では `-a`（上限金額）と `--force` も指定可能です。詳しくは `./gcp-spend-cap.sh --help` を参照してください。

## Google Cloud コンソールでの確認方法

設定した上限予算は、Google Cloud コンソールの **[予算とアラート]** ページからも確認や編集、一時停止の解除を行えます。お持ちの権限に応じて次の手順で開きます。

- **請求先アカウントの権限がある場合**: Google Cloud コンソールで [予算とアラート](https://console.cloud.google.com/billing/budgets) を開き、対象の Cloud 請求先アカウントを選択します。
- **プロジェクト単位の権限のみの場合**: 先に Google Cloud コンソール上部のプロジェクト セレクタで対象プロジェクトを選択してから、ナビゲーション メニューの **[お支払い]** を開きます（確認画面が出た場合は **[リンクされた請求先アカウントに移動]** を選択します）。続いて左側のメニューの **[費用管理]** から **[予算とアラート]** を選択します。

予算一覧の **単価の上限のステータス**（英語表示では **Spend cap status**）列には、次のいずれかが表示されます。

- **構成済み (Configured)**: 上限が有効に監視されており、まだ上限額には達していません。
- **適用済み (Enforced)**: 当月の推定費用が目標額に達し、対象サービスの新規利用が一時停止されています。コンソールから手動で再開するには、予算名をクリックして編集画面を開き、上限の解除（**Lift spend cap**）を選択して確定します。
- **解除済み (Lifted)**: 上限到達後に手動で解除された状態です。当月の残りの期間は、目標額を引き上げない限り再度停止されることはありません。
- **該当なし (Not applicable)**: 利用停止を伴わない通常のアラート専用予算です。

## 動作仕様

各コマンドは安全に運用できるよう次のルールで動作します。

- `set` は変更プランを表示したうえで確認を求め、既存の上限予算があればその場で金額を更新します。すでに上限に達して利用停止中（`ENFORCED`）の予算は、解除すると利用が再開されるため、`--force` を付けた場合のみ更新します。
- `lift` は上限に達して停止中（`ENFORCED`）の予算のみを解除します。一度解除した予算は、`set` で上限額を引き上げない限り翌月まで停止機能がオフのままになります。解除後、サービスの利用が再開されるまで最大 1 時間かかる場合があります。
- `delete` は停止中の予算がある場合に API の制約に従って先に解除してから削除します。
- 複数サービスを処理する際、一部のサービスでエラーが起きても残りのサービスの処理は続行されます。失敗またはスキップされた項目が 1 つでもある場合、終了コードは `1` になります。
- アクセス トークンは一時ファイル経由で `curl` に渡されるため、プロセス一覧（`ps`）には露出しません。

## 無料クレジットやクーポンがある場合の運用方法

Spend Cap は API の必須制約（`EXCLUDE_ALL_CREDITS`）により割引前の正規価格で集計されるため、無料トライアル クレジットや追加クーポンで支払われる利用分も上限額に向かってカウントされます。クーポンを使い切って実質課金が発生するときだけ止めたい場合は、**「今月使うクーポン残高 ＋ 許容できる実課金額」** を `-a` の上限額に設定して運用します。

- **設定例**: 30,000 円分のクーポンがあり、実課金が 1,000 円を超えたら止めたい場合は `-a 31000` を指定します。実質負担を 0 円のままクーポン枠内に収めたい場合は、集計ラグを見込んでクーポン残高より少し低い `-a 28000` などを設定してください。
- **月初の残高見直し**: Spend Cap の月間カウントは毎月 1 日に 0 円へ戻りますが、クーポン残高は月をまたいで減っていきます。月初に Google Cloud コンソールの **[お支払い]** 内にある **[クレジット]** で残高を確認し、`./gcp-spend-cap.sh set` でその月の上限額を調整してください。どのコマンドも実行時に、この [クレジット] ページの URL を `Credits:` 行に表示します（残高を返す公開 API がないため、残高そのものは表示しません）。
- **複数サービスでの配分**: 上限はサービス単位でかかるため、1 つのクーポンを複数サービス（Gemini API と Cloud Run など）で併用する場合は、残高を各サービスの上限額に振り分けて設定します。

## 制限事項と月次リセットの仕組み

Cloud Billing の費用上限予算には、あらかじめ押さえておくべき仕様上の制約があります。

- 費用計算には割引前の正規価格に基づく推定費用が使われます。集計には 10 分前後のタイムラグがあり、処理中のリクエストは完了まで動くため、わずかな超過分は通常どおり課金されます。絶対超えたくない金額より少し低めに設定してください。
- クレジットや各種割引は計算から除外されます（API 仕様上 `EXCLUDE_ALL_CREDITS` が必須です）。クーポン併用時の設定方法は上の「無料クレジットやクーポンがある場合の運用方法」を参照してください。
- Cloud Run の最小インスタンス数やストレージ料金など、継続的に発生する固定費は一時停止の対象外です。
- **毎月 1 日のリセットについて**: 毎月 1 日（米国・カナダ太平洋時間の午前 0 時）にリセットされるのは「当月の累計利用額（0 に戻る）」と「停止・解除ステータス（`ENFORCED` や `AWAITING_NEXT_PERIOD` が再び `CONFIGURED` に戻り、停止中のサービスが自動再開される）」です。**設定した上限予算そのものは消えずに翌月以降もそのまま維持されるため、毎月設定し直す必要はありません。** なお、費用上限予算は月次（`MONTH`）のみに対応しており、月が変わっても自動再開させない通算上限やカスタム期間は API の仕様上設定できません。
- Context-Aware Access (CAA) のクライアント証明書には対応していないため、CAA で保護されたアカウントのトークンは拒否される場合があります。

## 必要な権限

対象プロジェクト上で `resourcemanager.projects.get`、`billing.resourcebudgets.read`、`billing.resourcebudgets.write`、`billing.resourcebudgets.configureSpendCap`、`serviceusage.services.use`（初回に `--enable-api` を使う場合は `serviceusage.services.enable` も）が必要です。請求先アカウント管理者（Billing Account Administrator）ロールでも予算操作を行えますが、プロジェクト情報の取得と API 呼び出しのためにプロジェクト側の `resourcemanager.projects.get` と `serviceusage.services.use` はあわせて必要になります。また、通貨コードの表示には請求先アカウント上の `billing.accounts.get` が使われます。

## 参考ドキュメント

詳しい API 仕様やコンソール手順は次の公式ドキュメントを参照してください。

- [費用の上限の予算を管理する](https://cloud.google.com/billing/docs/how-to/budgets-spend-caps?hl=ja)
- [Cloud Billing Budget API を使用して費用の上限の予算を管理する](https://cloud.google.com/billing/docs/how-to/budget-api-spend-cap?hl=ja)
