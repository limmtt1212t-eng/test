from pathlib import Path


# Укажи путь к исходному CSV из DBeaver.
INPUT_CSV = Path(r"C:\путь\объекты.csv")

# Это будет новая копия, которую можно открывать двойным кликом в Excel.
OUTPUT_CSV = Path(r"C:\путь\объекты_для_excel.csv")


UTF8_BOM = b"\xef\xbb\xbf"
source_bytes = INPUT_CSV.read_bytes()

# Убираем BOM из рабочей копии, если он уже был, чтобы не продублировать его.
if source_bytes.startswith(UTF8_BOM):
    source_bytes = source_bytes[len(UTF8_BOM):]

# sep=; — служебная строка Excel. Она заставляет Excel использовать
# точку с запятой независимо от региональных настроек компьютера.
EXCEL_SEPARATOR_HINT = b"sep=;\r\n"

if not source_bytes.lower().startswith(b"sep=;"):
    source_bytes = EXCEL_SEPARATOR_HINT + source_bytes

# Исходный файл не изменяется. В новую копию добавляются только:
# 1) метка кодировки UTF-8 BOM;
# 2) подсказка Excel о разделителе столбцов.
output_bytes = UTF8_BOM + source_bytes

OUTPUT_CSV.write_bytes(output_bytes)

print("Готово:", OUTPUT_CSV)
print("Исходный CSV не изменён:", INPUT_CSV)
