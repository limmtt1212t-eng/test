# Агрегированные признаки из хэштегов для GLM КАСКО (v4)

## Цель

Построить агрегированные поведенческие признаки из TAG.

## Данные

| Параметр | Значение |
|----------|----------|
| Источник | Полисы КАСКО с хэштегами |
| Целевая переменная | `BINARY_CLAIMS_PART_DAM_COUNT` — наличие частичного убытка (0/1) |
| Файлы данных | 2 CSV + 1 Excel-справочник (пути в `config.py`) |

### Тематические группы TAG

| Группа | TAG | Примеры |
|--------|-----|---------|
| `auto_lover` | 67 | Парковка, АЗС, запчасти, каршеринг, автомойки, штрафы ГИБДД |
| `shopping` | 89 | Одежда, супермаркеты, аптеки, техника, косметика, товары для дома |
| `alcohol` | 16 | Бары, пабы, алкомаркеты, покупка пива/вина |

## Методология

### auto_lover, shopping — L1 LogReg + целочисленные веса

Реализовано в классе `IntegerMonotonicLinearGrouper` (research-ноутбуки):

1. **L1-логистическая регрессия** (`penalty='l1'`, `solver='saga'`, `C=0.35`) — отбор значимых TAG и получение сырых весов
2. **Целочисленное квантование** — нормализация весов в диапазон [1, 10], округление до целых
3. **Grid search** по `(tag_count x n_groups)` с фильтрацией по монотонности (`up_share >= 0.70`, `slope > 0`)
4. **Фиксация весов** — найденные оптимальные целочисленные веса записываются в `FINAL_WEIGHTS` в `config.py`
5. **Итоговый расчет** — взвешенная сумма `X @ weights` + `MinMaxScaler` в [0, 1]

### alcohol — простая сумма

Алкогольные TAG имеют небольшое количество (16), сложная модель не требуется:

1. Суммирование всех TAG группы
2. `MinMaxScaler` в [0, 1]
3. Квантильный биннинг 

## Порядок запуска

Для получения итогового файла достаточно двух файлов:

```
config.py + clustering_agg_v4.ipynb → artifacts/csv/all_groups_agg_coef.csv
```

Веса уже зафиксированы в `FINAL_WEIGHTS` в `config.py`. Research-ноутбуки нужны только при пересмотре весов:

```
1. research/clustering_monotonic_auto_lover_v4.ipynb    → подбор весов auto_lover
2. research/clustering_monotonic_shopping_features_v4.ipynb → подбор весов shopping
3. research/clustering_alcohol_v4.ipynb                 → анализ alcohol
   ↓
   Скопировать веса из export-weights ячеек в FINAL_WEIGHTS в config.py
   ↓
4. clustering_agg_v4.ipynb                              → итоговый файл
```

## Итоговый файл

`clustering_agg_v4.ipynb` → `artifacts/csv/all_groups_agg_coef.csv`

| Колонка | Тип | Описание |
|---------|-----|----------|
| `POLICY_ZV` | index | Идентификатор полиса |
| `auto_lover_agg_coef` | float [0, 1] | Взвешенный скор автолюбителя (MinMax) |
| `auto_lover_agg_coef_bin` | int 0/1 | Бинаризация по порогу 0.5 |
| `shopping_agg_coef` | float [0, 1] | Взвешенный скор шопинга (MinMax) |
| `shopping_agg_coef_bin` | int 0/1 | Бинаризация по порогу 0.5 |
| `alcohol_agg_coef` | float [0, 1] | Сумма алкогольных TAG (MinMax) |
| `alcohol_agg_coef_bin` | int 0/1 | Бинаризация по порогу 0.5 |
| `agg_alcohol` | int 0–13 | Квантильный биннинг алкоголя |

## Финальные веса

Единый источник правды: `config.py` → `FINAL_WEIGHTS`.

**auto_lover** (17 TAG):

| TAG | Вес | Описание |
|-----|-----|----------|
| TAG_10615 | 10 | Оплата парковки |
| TAG_20158 | 6 | АЗС Газпром |
| TAG_22019 | 5 | Запчасти Exist.ru |
| TAG_20178 | 5 | Нефтьмагистраль |
| TAG_10616 | 4 | Товары для нового авто |
| TAG_15296 | 4 | Каршеринг (редко) |
| TAG_21998 | 4 | Запчасти Авторусь |
| TAG_22560 | 3 | Автомасла |
| TAG_10612 | 3 | Автомойки |
| TAG_11517 | 2 | Товары для охоты |
| TAG_15788 | 2 | Каршеринг Делимобиль |
| TAG_10293 | 2 | Оплата штрафов |
| TAG_27777 | 2 | Штрафы ГИБДД |
| TAG_20170 | 2 | АЗС Трасса |
| TAG_15785 | 2 | Каршеринг ЯндексДрайв |
| TAG_20144 | 1 | АЗС Shell |
| TAG_21948 | 1 | Шиномонтаж |

**shopping** (40 TAG): веса от 10 до 1, полный перечень в `config.py`.

**alcohol**: без весов (простая сумма всех 16 TAG).

## Структура проекта

```
casco_hashtag_features/
├── config.py                           # Пути, списки фичей, FINAL_WEIGHTS
├── clustering_agg_v4.ipynb             # Итоговый ноутбук
├── README.md
│
├── artifacts/
│   └── csv/
│       └── all_groups_agg_coef.csv     # Итоговый файл (7 колонок)
│
└── research/
    ├── clustering_monotonic_auto_lover_v4.ipynb      # Grid search весов auto_lover
    ├── clustering_monotonic_shopping_features_v4.ipynb # Grid search весов shopping
    └── clustering_alcohol_v4.ipynb                    # Анализ alcohol (простая сумма)
```

## Конфигурация

Все параметры сосредоточены в `config.py`:

- **Пути к данным**: `TAGS_EXCEL_PATH`, `DATA_CSV_PART1`, `DATA_CSV_PART2`
- **Списки фичей**: `auto_lover`, `alcohol_features`, `shopping_features` (человекочитаемые названия)
- **Финальные веса**: `FINAL_WEIGHTS` (целочисленные, из research-ноутбуков)
- **Маппинг**: `load_tag_lists()` — преобразование названий в коды `TAG_*` через Excel-справочник

## Зависимости

- Python 3.8+
- pandas, numpy
- scikit-learn (MinMaxScaler, LogisticRegression)
- matplotlib
- openpyxl (чтение Excel)
