from pathlib import Path


# Укажи путь к исходному CSV из DBeaver.
INPUT_CSV = Path(r"C:\путь\объекты.csv")

# Это будет новая копия, которую можно открывать двойным кликом в Excel.
OUTPUT_CSV = Path(r"C:\путь\объекты_для_excel.csv")


UTF8_BOM = b"\xef\xbb\xbf"
source_bytes = INPUT_CSV.read_bytes()

# Исходный файл не изменяется. В новую копию добавляется только метка
# кодировки UTF-8, чтобы Excel правильно показывал русский текст.
if source_bytes.startswith(UTF8_BOM):
    output_bytes = source_bytes
else:
    output_bytes = UTF8_BOM + source_bytes

OUTPUT_CSV.write_bytes(output_bytes)

print("Готово:", OUTPUT_CSV)
print("Исходный CSV не изменён:", INPUT_CSV)
