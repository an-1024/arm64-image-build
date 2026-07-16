#!/bin/bash

cd ~/Dev_AZH/work_files/项目文档/福建医科大/uosimage/arm64-image-build

# 先清理之前的 LFS 相关配置
git lfs untrack "libreoffice-rpms/*" 2>/dev/null
rm -f .gitattributes

for file in libreoffice-rpms/RPMS/*.rpm; do
    filename=$(basename "$file")
    echo "========== 正在提交: $filename =========="

    git add "$file"
    git commit -m "Add $filename"
    git push origin main

    echo "========== 完成: $filename =========="
    echo ""
done

echo "全部处理完毕！"
