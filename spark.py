import csv
import json
import requests
import uuid
from typing import Dict, List, Optional

# Настройки
SPARK_URL = "http://cpre-cnv-lb-vip.sberins.ru/axilink-service/axilink-1.0/api/v1/sync"  # Замените на ваш URL
INPUT_CSV = "inn.csv"  # Ваш входной CSV с колонкой 'inn'
OUTPUT_CSV = "output_inn.csv"


def generate_guid():
    return str(uuid.uuid4())


def safe_get(d: Dict, *keys, default=""):
    """Безопасное извлечение вложенных значений"""
    for key in keys:
        if isinstance(d, dict):
            d = d.get(key, {})
        else:
            return default
    return d if d != {} else default


def safe_get_attr(d: Dict, attr: str, default=""):
    """Безопасное извлечение атрибута (@attr)"""
    if isinstance(d, dict):
        return d.get(f"@{attr}", default)
    return default


def safe_get_value(d: Dict, default=""):
    """Безопасное извлечение _value"""
    if isinstance(d, dict):
        return d.get("_value", default)
    return default


def call_spark_api(inn: str) -> Optional[Dict]:
    """Вызов SPARK API для получения данных по ИНН"""
    payload = {
        "techData": {
            "runId": generate_guid(),
            "correlationId": generate_guid(),
            "call_name": "SPARK_COMPANY_SPARK_RISKS_REPORT_XML"
        },
        "businessData": {
            "Application": {
                "AXI": {
                    "application_e": {
                        "@inn": inn
                    }
                }
            }
        }
    }

    try:
        response = requests.post(SPARK_URL, json=payload, timeout=30)
        response.raise_for_status()
        return response.json()
    except Exception as e:
        print(f"Ошибка при запросе для ИНН {inn}: {e}")
        return None


def extract_sro_themes(report: Dict) -> str:
    """Извлечь тематики СРО через запятую"""
    sros = report.get("SROs", {}).get("SRO", [])
    if not sros or not isinstance(sros, list):
        return ""

    themes = []
    for sro in sros:
        if isinstance(sro, dict):
            theme = sro.get("Type", {}).get("@Name", "")
            if theme:
                themes.append(theme)

    return "| ".join(themes)


def extract_tender_info(report: Dict) -> Dict:
    """Извлечь информацию по тендерам и контрактам"""
    state_contracts = report.get("StateContracts", {})
    tenders = state_contracts.get("Tenders", {})
    contracts = state_contracts.get("Contracts", {})

    return {
        "tenders_admitted": tenders.get("@AdmittedNumber", "0") if isinstance(tenders, dict) else "0",
        "tenders_winner": tenders.get("@WinnerNumber", "0") if isinstance(tenders, dict) else "0",
        "tenders_not_admitted": tenders.get("@NotAdmittedNumber", "0") if isinstance(tenders, dict) else "0",
        "contracts_signed": contracts.get("@SignedNumber", "0") if isinstance(contracts, dict) else "0"
    }


def extract_financial_data(report: Dict) -> Dict:
    """Извлечь финансовые данные за 2025 и динамику с 2024"""
    finance = report.get("Finance", {})
    fin_periods = finance.get("FinPeriod", [])

    if not isinstance(fin_periods, list):
        fin_periods = []

    data_2024 = {}
    data_2025 = {}

    for period in fin_periods:
        if not isinstance(period, dict):
            continue

        period_name = period.get("@PeriodName", "")
        indicators_list = period.get("Indicator", [])

        if not isinstance(indicators_list, list):
            continue

        indicators = {}
        for ind in indicators_list:
            if isinstance(ind, dict) and "@Name" in ind:
                indicators[ind["@Name"]] = ind.get("@Value", "0")

        if period_name == "2024":
            data_2024 = indicators
        elif period_name == "2025":
            data_2025 = indicators

    def calc_dynamic(val_2025, val_2024):
        try:
            v2025 = float(str(val_2025).replace(",", ".").replace(" ", ""))
            v2024 = float(str(val_2024).replace(",", ".").replace(" ", ""))
            if v2024 == 0:
                return "N/A"
            dynamic = ((v2025 - v2024) / abs(v2024)) * 100
            return f"{dynamic:.2f}%"
        except:
            return "N/A"

    metrics = ["Выручка", "Чистая прибыль (убыток)",
               "Сальдо денежных потоков за отчетный период",
               "Чистые активы"]

    result = {}
    for metric in metrics:
        val_2025 = data_2025.get(metric, "0")
        val_2024 = data_2024.get(metric, "0")
        result[f"{metric}_2025"] = val_2025
        result[f"{metric}_dynamic"] = calc_dynamic(val_2025, val_2024)

    return result


def extract_consolidated_indicators(report: Dict) -> Dict:
    """Извлечь 3 скора из ConsolidatedIndicator"""
    consolidated = report.get("ConsolidatedIndicator", {})
    add_info = consolidated.get("AddInfo", {}).get("AddField", [])

    if not isinstance(add_info, list):
        add_info = []

    scores = {
        "IndexOfDueDiligence": "",
        "FailureScore": "",
        "PaymentIndex": ""
    }

    for field in add_info:
        if isinstance(field, dict):
            name = field.get("@Name", "")
            value = field.get("_value", "")
            if name in scores:
                scores[name] = value if value else ""

    return scores


def extract_include_in_list(report: Dict) -> str:
    """Извлечь списки, в которые входит компания"""
    include_list = report.get("IncludeInList", {}).get("ListName", [])

    if not isinstance(include_list, list):
        return ""

    names = []
    for item in include_list:
        if isinstance(item, dict):
            value = item.get("_value", "")
            if value:
                names.append(value)

    return "| ".join(names)


def process_spark_response(response_data: Dict) -> Dict:
    """Обработать ответ от SPARK API и извлечь нужные поля"""
    try:
        # Безопасное извлечение Report
        report = (response_data
                  .get("businessData", {})
                  .get("Application", {})
                  .get("AXI", {})
                  .get("application_e", {})
                  .get("SPARK_COMPANY_SPARK_RISKS_REPORT_XML", {})
                  .get("Data", {})
                  .get("Report", {}))

        if not report or not isinstance(report, dict):
            print("Не удалось извлечь Report из ответа")
            return {}

        # SRO
        sro_themes = extract_sro_themes(report)

        # Субсидии
        subsidies_sum = safe_get_value(report.get("SubsidiesSum", {}), "0")

        # Тендеры и контракты
        tender_info = extract_tender_info(report)

        # Различные счетчики - все через safe_get_value
        industrial_models = safe_get_value(report.get("IndustrialModelsNumber", {}), "0")
        inventions = safe_get_value(report.get("InventionsNumber", {}), "0")
        trademarks = safe_get_value(report.get("TrademarksNumber", {}), "0")

        # Природные объекты
        natural_objects = report.get("NaturalObjects", {})
        if not isinstance(natural_objects, dict):
            natural_objects = {}
        forest_areas = natural_objects.get("@ForestAreasNumber", "0")
        water_bodies = natural_objects.get("@WaterBodiesNumber", "0")
        wood_deals = natural_objects.get("@WoodDealsNumber", "0")

        # Исполнительные производства
        exec_proceedings = report.get("ExecutionProceedings", {})
        if not isinstance(exec_proceedings, dict):
            exec_proceedings = {}
        active_exec = exec_proceedings.get("@Active", "0")

        # Имущество
        property_info = report.get("Property", {})
        if not isinstance(property_info, dict):
            property_info = {}
        real_properties = property_info.get("@RealPropertiesNumber", "0")
        customs_warehouses = property_info.get("@CustomsWarehousesNumber", "0")

        # Залоги
        mortgage_properties = safe_get_value(report.get("MortgagePropertiesNumber", {}), "0")
        pledger = report.get("Pledger", {})
        if not isinstance(pledger, dict):
            pledger = {}
        active_pledges = pledger.get("@Active", "0")
        ceased_pledges = pledger.get("@Ceased", "0")

        # Лицензии
        active_licenses = safe_get_value(report.get("ActiveLicensesNumber", {}), "0")

        # Консолидированные индикаторы
        consolidated_scores = extract_consolidated_indicators(report)

        # Интегральные схемы
        integrated_circuits = safe_get_value(report.get("IntegratedCircuitTopographiesNumber", {}), "0")

        # ПО
        application_software = safe_get_value(report.get("ApplicationSoftwareNumber", {}), "0")

        # Проверки с нарушениями
        inspections = report.get("Inspections", {})
        if not isinstance(inspections, dict):
            inspections = {}
        inspections_with_violations = inspections.get("@WithViolations", "0")

        # Такси
        active_taxi = safe_get_value(report.get("ActiveTaxiPermitsNumber", {}), "0")

        # ОКВЭД
        okved = report.get("OKVED", {})
        if not isinstance(okved, dict):
            okved = {}
        okved_code = okved.get("@Code", "")
        okved_name = okved.get("@Name", "")

        # Финансы
        financial_data = extract_financial_data(report)

        # Лизинг
        lessee = report.get("Lessee", {})
        if not isinstance(lessee, dict):
            lessee = {}
        active_leases = lessee.get("@Active", "0")

        # Списки
        include_in_list = extract_include_in_list(report)

        return {
            "sro_themes": sro_themes,
            "subsidies_sum": subsidies_sum,
            **tender_info,
            "industrial_models_number": industrial_models,
            "inventions_number": inventions,
            "trademarks_number": trademarks,
            "forest_areas_number": forest_areas,
            "water_bodies_number": water_bodies,
            "wood_deals_number": wood_deals,
            "active_execution_proceedings": active_exec,
            "real_properties_number": real_properties,
            "mortgage_properties_number": mortgage_properties,
            "customs_warehouses_number": customs_warehouses,
            "active_licenses_number": active_licenses,
            "index_of_due_diligence": consolidated_scores["IndexOfDueDiligence"],
            "failure_score": consolidated_scores["FailureScore"],
            "payment_index": consolidated_scores["PaymentIndex"],
            "integrated_circuit_topographies_number": integrated_circuits,
            "application_software_number": application_software,
            "inspections_with_violations": inspections_with_violations,
            "active_pledges": active_pledges,
            "ceased_pledges": ceased_pledges,
            "active_taxi_permits_number": active_taxi,
            "okved_code": okved_code,
            "okved_name": okved_name,
            **financial_data,
            "active_leases": active_leases,
            "include_in_list": include_in_list
        }

    except Exception as e:
        print(f"Ошибка при обработке ответа: {e}")
        import traceback
        traceback.print_exc()
        return {}


def main():
    # Чтение входного CSV
    with open(INPUT_CSV, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        print(reader)
        inns = [row['inn'] for row in reader]

    print(f"Найдено {len(inns)} ИНН для обработки")

    results = []

    for idx, inn in enumerate(inns, 1):
        print(f"Обработка {idx}/{len(inns)}: ИНН {inn}")

        response_data = call_spark_api(inn)

        if response_data:
            extracted_data = process_spark_response(response_data)
        else:
            extracted_data = {}

        result = {"inn": inn, **extracted_data}
        results.append(result)

        # Небольшая пауза между запросами
        import time
        time.sleep(0.5)

    # Запись результатов
    if results:
        fieldnames = list(results[0].keys())

        with open(OUTPUT_CSV, 'w', encoding='utf-8-sig', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames, delimiter=';')
            writer.writeheader()
            writer.writerows(results)

        print(f"Результаты сохранены в {OUTPUT_CSV}")
    else:
        print("Нет данных для сохранения")


if __name__ == "__main__":
    main()