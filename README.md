# Unity-Packager

指定したディレクトリ内のアセットと対応する `.meta` ファイルを収集し、`.unitypackage` フォーマットでアーカイブする。

## 使用方法

```bash
unity_packager [options] <inputDir> <outputFile.unitypackage>
```

### オプション

- `-d`, `--dependencies[=true|false]`: 依存関係を含めるか指定（デフォルト: false）
