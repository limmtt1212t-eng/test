from pathlib import Path


# Укажи путь к исходному CSV из DBeaver.
INPUT_CSV = Path(r"C:\путь\объекты.csv")

# Это будет новая копия, которую можно открывать двойным кликом в Excel.
OUTPUT_CSV = Path(r"C:\путь\объекты_для_excel.csv")


source_bytes = INPUT_CSV.read_bytes()

# Исходная выгрузка DBeaver имеет кодировку UTF-8. Декодирование utf-8-sig
# одинаково работает и с BOM, и без него.
source_text = source_bytes.decode("utf-8-sig")

# sep=; — служебная строка Excel. Она заставляет Excel использовать
# точку с запятой независимо от региональных настроек компьютера.
EXCEL_SEPARATOR_HINT = "sep=;\r\n"

if not source_text.lower().startswith("sep=;"):
    source_text = EXCEL_SEPARATOR_HINT + source_text

# UTF-16 LE с BOM Excel надёжно распознаёт в разных версиях Windows
# независимо от региональных настроек. Содержание значений сохраняется:
# меняется только внешняя кодировка Excel-копии.
UTF16LE_BOM = b"\xff\xfe"
output_bytes = UTF16LE_BOM + source_text.encode("utf-16-le")

OUTPUT_CSV.write_bytes(output_bytes)

print("Готово:", OUTPUT_CSV)
print("Исходный CSV не изменён:", INPUT_CSV)
