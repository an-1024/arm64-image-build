#!/bin/bash


# 先清理之前的 LFS 相关配置
git lfs untrack "libreoffice-rpms/*"
rm -f .gitattributes

for file in libreoffice-rpms/*.rpm; do
    filename=$(basename "$file")
    echo "========== 正在提交: $filename =========="

    git add "$file"
    git commit -m "Add $filename"
    git push origin main

    echo "========== 完成: $filename =========="
    echo ""
done

echo "全部处理完毕！"
