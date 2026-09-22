"""Generate explicitly synthetic 15001-row fixtures for manual UI checks."""
import csv
import sys
from pathlib import Path
import openpyxl

if __name__ == '__main__':
    target = Path(sys.argv[1])
    target.mkdir(parents=True, exist_ok=True)
    book = openpyxl.Workbook()
    with (target / 'synthetic-15001.csv').open('w', newline='', encoding='utf-8-sig') as output:
        writer = csv.writer(output, delimiter=';')
        headers = ['ФИО', 'СНИЛС', 'Телефон', 'Бюджет', 'Условие']
        writer.writerow(headers); book.active.append(headers)
        for n in range(15001):
            row = ['Иванов Иван Иванович', str(10000000000+n), f'8999{n:07d}', 120000, 'не согласовал']
            writer.writerow(row); book.active.append(row)
    book.save(target / 'synthetic-15001.xlsx')
    print(target)
