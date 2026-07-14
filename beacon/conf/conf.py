import logging
import yaml
from beacon.exceptions.exceptions import FileNotFound

try:
    with open("beacon/conf/api_version.yml") as api_version_file:
        api_version_yaml = yaml.safe_load(api_version_file)
except Exception as e:
    raise FileNotFound('There are issues with the api_version.yml file. Check if it can be opened or if has any content')

level=logging.DEBUG
log_file = '/beacon/logs/beacon.log'
beacon_id = 'es.isciii-ciber.beacon'
beacon_name = 'ISCIII-CIBER Spain AF Beacon'
api_version = 'v2.2.0' # Version of the Beacon implementation
uri = 'http://beaconprod:5050'
uri_subpath = '/api'
complete_url = uri + uri_subpath
environment = 'TEST'
description = r"This Beacon is based on synthetic data hosted at the <a href='https://ega-archive.org/datasets/EGAD00001003338'>EGA</a>. The dataset contains 2504 samples including genetic data based on 1K Genomes data, and 76 individual attributes and phenotypic data derived from UKBiobank."
version = api_version_yaml['api_version']
welcome_url = 'https://isciii.es/'
alternative_url = 'http://beaconaf-isciiiciber.isciiides.es:8443'
create_datetime = '2026-02-11T00:00:00.000000Z'
update_datetime = ''
default_beacon_granularity = "record" # boolean, count or record
security_levels = ['PUBLIC', 'REGISTERED', 'CONTROLLED']
documentation_url = 'https://b2ri-documentation-demo.ega-archive.org/'
cors_urls = ['http://localhost:3003', 'http://localhost:3000', 'http://beaconaf-isciiiciber.isciiides.es:8443', 'http://apibeacon-isciiiciber.isciiides.es:8443']
max_limit_of_records_per_dataset_in_a_page=100
pending_requests_timeout_in_seconds=10 # Timeout waiting pending requests

# Service Info
ga4gh_service_type_group = 'org.ga4gh'
ga4gh_service_type_artifact = 'beacon'
ga4gh_service_type_version = '1.0'

# Organization info
org_id = 'ISCIII'
org_name = 'Instituto de Salud Carlos III'
org_description = 'El Instituto de Salud Carlos III es el principal organismo público de investigación biomédica y en salud de España.'
org_adress = 'C/ Monforte de Lemos, 5, 28029 Madrid, Spain'
org_welcome_url = 'https://www.isciii.es/'
org_contact_url = 'mailto:bioinformatica@isciii.es'
org_logo_url = 'https://www.isciii.es/images/logo.png'
org_info = ''

# Certificates
beacon_server_crt = ''
beacon_server_key = ''

# Query Budget
query_budget_per_user = False
query_budget_per_ip = False
query_budget_amount = 3
query_budget_time_in_seconds = 20
query_budget_database = 'mongo'
query_budget_db_name = 'beacon'
query_budget_table = 'budget'

# Query Rounding
imprecise_count=0 # If imprecise_count is 0, no modification of the count will be applied. If it's different than 0, count will always be this number when count is smaller than this number.
round_to_tens=False # If true, the rounding will be done to the immediate superior tenth if the imprecise_count is 0
round_to_hundreds=False # If true, the rounding will be done to the immediate superior hundredth if the imprecise_count is 0 and the round_to_tens is false