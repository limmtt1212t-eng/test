import pandas as pd


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

df.to_excel(
    r"C:\путь\объекты.xlsx",
    index=False,
)
