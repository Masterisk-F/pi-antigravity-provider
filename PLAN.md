# Plan: `preferredDialect` is not a function エラーの修正

## 背景
`pi-antigravity-provider` プラグインは、`sync.sh` スクリプトを使って上流の `oh-my-pi` からコードをバンドルしています。バンドル時に `@oh-my-pi/*` インポートがすべて `@earendil-works/pi-ai` に置換されます。しかし、関数 `preferredDialect` は上流の `@oh-my-pi/pi-catalog/identity` に存在しますが、**`@earendil-works/pi-ai` には存在しません**（古いバージョンからフォークされているため）。

プラグインが `pi` アプリケーションで実行されると、`@earendil-works/pi-ai` をインポートしますが、これは `compat` エントリポイントに解決されます。`preferredDialect` がエクスポートされていないため、インポートが `undefined` になり、以下のエラーが発生します：
```
Error: (0, _piAi.preferredDialect) is not a function. (In '(0, _piAi.preferredDialect)(modelId)', '(0, _piAi.preferredDialect)' is undefined)
```

モデル切り替え時に発生するのは、`renderDemotedThinking` が `preferredDialect(modelId)` を呼び出すためです。

## 根本原因
`sync.sh` スクリプトが無条件にすべての `@oh-my-pi/*` 参照を `@earendil-works/pi-ai` に置換しています：
```bash
sed -i -E 's|@oh-my-pi/[a-zA-Z0-9/-]+|@earendil-works/pi-ai|g' plugin-bundled.js
```

これにより、`preferredDialect` をエクスポートしている `@oh-my-pi/pi-catalog/identity` が、それを持たない `@earendil-works/pi-ai` に誤ってマッピングされています。

## アプローチ
**上流（oh-my-pi）から実際の実装を取得してバンドルに含める**。ローカル実装ではなく、上流のソースコードを `sync.sh` で取得してバンドルに組み込むことで、完全な互換性を確保します。

上流の実装は以下にあります：
- `@oh-my-pi/pi-catalog/src/identity/dialect.ts` - `preferredDialect` 関数
- `@oh-my-pi/pi-catalog/src/identity/family.ts` - `modelFamilyToken` と分類関数
- `@oh-my-pi/pi-catalog/src/identity/classify.ts` - `parseKnownModel` など

これらを `sync.sh` で取得し、バンドルに含めます。

## 修正対象ファイル
1. `sync.sh` - 上流から必要なソースファイルを取得し、バンドルに含める

## 既存コードの再利用
- バンドルにはすでに `getDialectDefinition` と `DIALECT_DEFINITIONS` が含まれています（plugin-bundled.js の 31823-31824 行目）
- `renderDemotedThinking` 関数（32090 行目）が `preferredDialect` を呼び出し、`getDialectDefinition` を使用
- 上流の実装をそのまま取り込むことで、`DIALECT_DEFINITIONS` にある有効な方言を正しく返せるようになります

## 実装計画
1. `sync.sh` に上流リポジトリから必要なファイルを取得するステップを追加：
   - `@oh-my-pi/pi-catalog/src/identity/dialect.ts` - `preferredDialect`, `Dialect`, `FALLBACK_DIALECT`
   - `@oh-my-pi/pi-catalog/src/identity/family.ts` - `modelFamilyToken`, 各種 `is*ModelId` 関数
   - `@oh-my-pi/pi-catalog/src/identity/classify.ts` - `parseKnownModel`, `bareModelId` など

2. これらをローカルファイルとしてコピーし、インポートパスを調整（内部インポートを相対パスに、`.js` 拡張子追加、外部依存は既存の polyfill 経由）

3. `pi-utils-polyfill.ts` または専用のファイルにこれらを再エクスポート

4. バンドル時にこれらが含まれるようにする

## 手順
- [ ] `sync.sh` で上流（oh-my-pi）から `dialect.ts`, `family.ts`, `classify.ts` を取得
- [ ] 依存関係のインポートパスをローカルファイルに向くように調整（`.js` 拡張子追加、内部インポートを相対パス化）
- [ ] これらをバンドルに含める（polyfill または専用エントリーポイント経由）
- [ ] `./sync.sh` 実行し、バンドルに `preferredDialect` 等が含まれることを確認
- [ ] モデル切り替え時にエラーが発生しないことを確認

## 検証
1. `./sync.sh` を実行してバンドルを再生成
2. `plugin-bundled.js` に `preferredDialect`, `modelFamilyToken` 等の実装が含まれることを確認
3. `pi` アプリケーションで Google Antigravity モデル間を切り替えてテスト