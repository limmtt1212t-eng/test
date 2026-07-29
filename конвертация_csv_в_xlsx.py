import re

import pandas as pd


# Excel не допускает некоторые невидимые управляющие символы.
# Обычные переносы строк (\n), возврат каретки (\r) и табуляция (\t)
# здесь намеренно сохраняются.
ILLEGAL_EXCEL_CHARACTERS = re.compile(r"[\x00-\x08\x0B\x0C\x0E-\x1F]")


def clean_for_excel(value):
    if isinstance(value, str):
        return ILLEGAL_EXCEL_CHARACTERS.sub("", value)
    return value


df = pd.read_csv(
    r"C:\путь\объекты.csv",
    sep=";",
    encoding="utf-8-sig",
    quotechar='"',
    dtype=str,
    keep_default_na=False,
    engine="python",
    on_bad_lines="error",
)

print("Количество строк:", len(df))
assert len(df) == 5000, f"Ожидалось 5000 строк, получено: {len(df)}"

# Удаляем только символы, запрещённые форматом XLSX.
df.columns = [clean_for_excel(str(column)) for column in df.columns]
df = df.apply(lambda column: column.map(clean_for_excel))

df.to_excel(
    r"C:\путь\объекты.xlsx",
    index=False,
)

print("Файл XLSX успешно создан")
