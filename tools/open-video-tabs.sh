#!/bin/bash
# Открывает все семь вкладок для записи демо-видео, слева направо в порядке сценария.
# Запуск:  bash ~/projects/airbag-hook/tools/open-video-tabs.sh

set -e

TABS=(
  "https://impetus82.github.io/airbag-hook/explainer/"                                        # 1 объяснительная страница
  "https://impetus82.github.io/airbag-hook/"                                                  # 2 приложение
  "https://basescan.org/tx/0x7fce3af9d3a92001ec85a613c6a865fe231a388c4f04631be8264230206f539b" # 3 постановка ордера
  "https://basescan.org/tx/0x46a3f13febfad4ed45d4248afed118703329da9018b636060aff3f39de547af7" # 4 своп
  "https://basescan.org/tx/0x728e0aff7d4b77558b670cba2fd0351031d9582044b0f2b6c80045dab9419534" # 5 клейм на Base
  "https://uniscan.xyz/tx/0x9d5c36f3b0bdd647c6e96dc234bcebe082ad64e24cd49b2f58c2ab28e833e006"  # 6 клейм на Unichain
  "https://github.com/impetus82/airbag-hook"                                                   # 7 репозиторий
)

echo "Открываю ${#TABS[@]} вкладок по порядку…"
for i in "${!TABS[@]}"; do
  printf "  %d/%d\n" $((i+1)) ${#TABS[@]}
  open "${TABS[$i]}"
  # пауза, иначе браузер может переставить вкладки местами
  sleep 1.2
done

echo
echo "Готово. Проверьте порядок слева направо и подключите кошелёк на вкладке 2."
