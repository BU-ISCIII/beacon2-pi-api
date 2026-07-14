from django import forms
import yaml
import logging
import os

LOG = logging.getLogger(__name__)
fmt = '%(levelname)s - %(asctime)s - %(message)s'
formatter = logging.Formatter(fmt)
sh = logging.StreamHandler()
sh.setLevel('NOTSET')
sh.setFormatter(formatter)
LOG.addHandler(sh)

def formatting_field(line):
    linestring=str(line)
    splitted_line=linestring.split("=")
    placeholder=splitted_line[1].replace('"', '')
    placeholder=str(placeholder)
    placeholder=placeholder.strip()
    if "#" in placeholder:
        placeholder_def=placeholder.split('#')
        placeholder=placeholder_def[0]
        placeholder=placeholder.strip()
    if placeholder.startswith("'"):
        placeholder=placeholder[1:]
    if placeholder.endswith("'"):
        placeholder=placeholder[0:-1]
    return placeholder

def get_entry_types(entry_type):
    with open("/home/app/web/beacon/models/ga4gh/beacon_v2_default_model/conf/entry_types/" + entry_type + ".yml") as f:
        conf = yaml.safe_load(f)[entry_type]
    lookups=[]
    active_entry_type=None
    active_endpoint_name=None
    placeholder = conf['endpoint_name']
    if placeholder != '':
        active_entry_type=entry_type
        active_endpoint_name=placeholder
    for lookup_name, lookup_conf in conf['lookups'].items():
        if lookup_conf['endpoint_enabled'] == True:
            lookups.append(lookup_name)
    if conf['allow_id_query'] == True:
        lookups.append(entry_type)
    return active_entry_type, active_endpoint_name, lookups

def generate_endpoints(choices, first_endpoint_name,second_endpoint_name,second_entry_type, lookups):
    for entry_type in lookups:
        if first_endpoint_name == second_endpoint_name and entry_type == second_entry_type:
            choices.append((first_endpoint_name+'/{id}', first_endpoint_name+'/{id}'))
        elif entry_type == second_entry_type:
                choices.append((first_endpoint_name+'/{id}/'+second_endpoint_name, first_endpoint_name+'/{id}/'+second_endpoint_name))
    return choices

def initialize_lookup_endpoints(entry_type, initial_choices):
    with open("/home/app/web/beacon/models/ga4gh/beacon_v2_default_model/conf/entry_types/" + entry_type + ".yml") as f:
        conf = yaml.safe_load(f)[entry_type]
    for lookup_name, lookup_conf in conf['lookups'].items():
        if lookup_conf['endpoint_enabled'] == True:
            initial_choices.append(lookup_conf['endpoint_name'])
    return initial_choices

class EntryTypesForm(forms.Form):
    def __init__(self, *args, **kwargs):
        super(EntryTypesForm, self).__init__(*args, **kwargs)
        # assign a (computed, I assume) default value to the choice field
        entry_types=[]
        endpoint_names=[]
        with open("/home/app/web/beacon/models/ga4gh/beacon_v2_default_model/conf/entry_types/" + "analysis.yml") as f:
            conf = yaml.safe_load(f)['analysis']
        analysis_initial_choices=[]
        analysis_endpoint_name = conf['endpoint_name']
        self.initial['AnalysisEndpointName'] = analysis_endpoint_name
        if analysis_endpoint_name != '':
            entry_types.append('analysis')
            endpoint_names.append(analysis_endpoint_name)
            self.initial['Analysis'] = True
        else:
            self.initial['Analysis'] = None
        if conf['allow_queries_without_filters'] == False:
            self.initial['AnalysisNonFiltered'] = None
        else:
            self.initial['AnalysisNonFiltered'] = True
        if conf['allow_id_query'] == True:
            analysis_initial_choices.append(analysis_endpoint_name+"/{id}")
        self.initial['analysis_granularity'] = conf['max_granularity']
        self.initial['analysis_engine'] = conf['connection']['name']
        with open("/home/app/web/beacon/models/ga4gh/beacon_v2_default_model/conf/entry_types/" + "biosample.yml") as f:
            conf = yaml.safe_load(f)['biosample']
        biosample_initial_choices=[]
        biosample_endpoint_name = conf['endpoint_name']
        self.initial['BiosampleEndpointName'] = biosample_endpoint_name
        if biosample_endpoint_name != '':
            entry_types.append('biosample')
            endpoint_names.append(biosample_endpoint_name)
            self.initial['Biosample'] = True
        else:
            self.initial['Biosample'] = None
        if conf['allow_queries_without_filters'] == False:
            self.initial['BiosampleNonFiltered'] = None
        else:
            self.initial['BiosampleNonFiltered'] = True
        if conf['allow_id_query'] == True:
            biosample_initial_choices.append(biosample_endpoint_name+"/{id}")
        self.initial['biosample_granularity'] = conf['max_granularity']
        self.initial['biosample_engine'] = conf['connection']['name']
        with open("/home/app/web/beacon/models/ga4gh/beacon_v2_default_model/conf/entry_types/" + "cohort.yml") as f:
            conf = yaml.safe_load(f)['cohort']
        cohort_initial_choices=[]
        cohort_endpoint_name = conf['endpoint_name']
        self.initial['CohortEndpointName'] = cohort_endpoint_name
        if cohort_endpoint_name != '':
            entry_types.append('cohort')
            endpoint_names.append(cohort_endpoint_name)
            self.initial['Cohort'] = True
        else:
            self.initial['Cohort'] = None
        if conf['allow_queries_without_filters'] == False:
            self.initial['CohortNonFiltered'] = None
        else:
            self.initial['CohortNonFiltered'] = True
        if conf['allow_id_query'] == True:
            cohort_initial_choices.append(cohort_endpoint_name+"/{id}")
        self.initial['cohort_granularity'] = conf['max_granularity']
        self.initial['cohort_engine'] = conf['connection']['name']
        with open("/home/app/web/beacon/models/ga4gh/beacon_v2_default_model/conf/entry_types/" + "dataset.yml") as f:
            conf = yaml.safe_load(f)['dataset']
        dataset_initial_choices=[]
        dataset_endpoint_name = conf['endpoint_name']
        self.initial['DatasetEndpointName'] = dataset_endpoint_name
        if dataset_endpoint_name != '':
            entry_types.append('dataset')
            endpoint_names.append(dataset_endpoint_name)
            self.initial['Dataset'] = True
        else:
            self.initial['Dataset'] = None
        if conf['allow_queries_without_filters'] == False:
            self.initial['DatasetNonFiltered'] = None
        else:
            self.initial['DatasetNonFiltered'] = True
        if conf['allow_id_query'] == True:
            dataset_initial_choices.append(dataset_endpoint_name+"/{id}")
        self.initial['dataset_granularity'] = conf['max_granularity']
        self.initial['dataset_engine'] = conf['connection']['name']
        with open("/home/app/web/beacon/models/ga4gh/beacon_v2_default_model/conf/entry_types/" + "genomicVariant.yml") as f:
            conf = yaml.safe_load(f)['genomicVariant']
        genomicVariant_initial_choices=[]
        genomicVariant_endpoint_name = conf['endpoint_name']
        self.initial['GenomicVariantEndpointName'] = genomicVariant_endpoint_name
        if genomicVariant_endpoint_name != '':
            entry_types.append('genomicVariant')
            endpoint_names.append(genomicVariant_endpoint_name)
            self.initial['GenomicVariant'] = True
        else:
            self.initial['GenomicVariant'] = None
        if conf['allow_queries_without_filters'] == False:
            self.initial['GenomicVariantNonFiltered'] = None
        else:
            self.initial['GenomicVariantNonFiltered'] = True
        if conf['allow_id_query'] == True:
            genomicVariant_initial_choices.append(genomicVariant_endpoint_name+"/{id}")
        self.initial['genomicVariation_granularity'] = conf['max_granularity']
        self.initial['genomicVariation_engine'] = conf['connection']['name']
        with open("/home/app/web/beacon/models/ga4gh/beacon_v2_default_model/conf/entry_types/" + "individual.yml") as f:
            conf = yaml.safe_load(f)['individual']
        individual_initial_choices=[]
        individual_endpoint_name = conf['endpoint_name']
        self.initial['IndividualEndpointName'] = individual_endpoint_name
        if individual_endpoint_name != '':
            entry_types.append('individual')
            endpoint_names.append(individual_endpoint_name)
            self.initial['Individual'] = True
        else:
            self.initial['Individual'] = None
        if conf['allow_queries_without_filters'] == False:
            self.initial['IndividualNonFiltered'] = None
        else:
            self.initial['IndividualNonFiltered'] = True
        if conf['allow_id_query'] == True:
            individual_initial_choices.append(individual_endpoint_name+"/{id}")
        self.initial['individual_granularity'] = conf['max_granularity']
        self.initial['individual_engine'] = conf['connection']['name']
        with open("/home/app/web/beacon/models/ga4gh/beacon_v2_default_model/conf/entry_types/" + "run.yml") as f:
            conf = yaml.safe_load(f)['run']
        run_initial_choices=[]
        run_endpoint_name = conf['endpoint_name']
        self.initial['RunEndpointName'] = run_endpoint_name
        if run_endpoint_name != '':
            entry_types.append('run')
            endpoint_names.append(run_endpoint_name)
            self.initial['Run'] = True
        else:
            self.initial['Run'] = None
        if conf['allow_queries_without_filters'] == False:
            self.initial['RunNonFiltered'] = None
        else:
            self.initial['RunNonFiltered'] = True
        if conf['allow_id_query'] == True:
            run_initial_choices.append(run_endpoint_name+"/{id}")
        self.initial['run_granularity'] = conf['max_granularity']
        self.initial['run_engine'] = conf['connection']['name']

        for endpoint in endpoint_names:
            if endpoint == analysis_endpoint_name:
                analysis_initial_choices=initialize_lookup_endpoints('analysis', analysis_initial_choices)
                self.initial['AnalysisEndpoints'] = analysis_initial_choices
            elif endpoint == biosample_endpoint_name:
                biosample_initial_choices=initialize_lookup_endpoints('biosample', biosample_initial_choices)
                self.initial['BiosampleEndpoints'] = biosample_initial_choices
            elif endpoint == cohort_endpoint_name:
                cohort_initial_choices=initialize_lookup_endpoints('cohort', cohort_initial_choices)
                self.initial['CohortEndpoints'] = cohort_initial_choices
            elif endpoint == dataset_endpoint_name:
                dataset_initial_choices=initialize_lookup_endpoints('dataset', dataset_initial_choices)
                self.initial['DatasetEndpoints'] = dataset_initial_choices
            elif endpoint == genomicVariant_endpoint_name:
                genomicVariant_initial_choices=initialize_lookup_endpoints('genomicVariant', genomicVariant_initial_choices)
                self.initial['GenomicVariantEndpoints'] = genomicVariant_initial_choices
            elif endpoint == individual_endpoint_name:
                individual_initial_choices=initialize_lookup_endpoints('individual', individual_initial_choices)
                self.initial['IndividualEndpoints'] = individual_initial_choices
            elif endpoint == run_endpoint_name:
                run_initial_choices=initialize_lookup_endpoints('run', run_initial_choices)
                self.initial['RunEndpoints'] = run_initial_choices

    def clean(self):
        cleaned_data = super(EntryTypesForm, self).clean()
        analysis = cleaned_data.get("Analysis")
        analysis_endpoint_name = cleaned_data.get("AnalysisEndpointName")
        if analysis_endpoint_name == '' and analysis != None:
            self.add_error('AnalysisEndpointName', 'If analysis is checked, analysis endpoint name can not be empty')
        biosample = cleaned_data.get("Biosample")
        biosample_endpoint_name = cleaned_data.get("BiosampleEndpointName")
        if biosample_endpoint_name == '' and biosample != None:
            self.add_error('BiosampleEndpointName', 'If biosample is checked, analysis endpoint name can not be empty')
        cohort = cleaned_data.get("Cohort")
        cohort_endpoint_name = cleaned_data.get("CohortEndpointName")
        if cohort_endpoint_name == '' and cohort != None:
            self.add_error('CohortEndpointName', 'If cohort is checked, analysis endpoint name can not be empty')
        dataset = cleaned_data.get("Dataset")
        dataset_endpoint_name = cleaned_data.get("DatasetEndpointName")
        if dataset_endpoint_name == '' and dataset != None:
            self.add_error('DatasetEndpointName', 'If dataset is checked, analysis endpoint name can not be empty')
        genomicVariant = cleaned_data.get("GenomicVariant")
        genomicVariant_endpoint_name = cleaned_data.get("GenomicVariantEndpointName")
        if genomicVariant_endpoint_name == '' and genomicVariant != None:
            self.add_error('GenomicVariantEndpointName', 'If genomicVariant is checked, analysis endpoint name can not be empty')
        individual = cleaned_data.get("Individual")
        individual_endpoint_name = cleaned_data.get("IndividualEndpointName")
        if individual_endpoint_name == '' and individual != None:
            self.add_error('IndividualEndpointName', 'If individual is checked, analysis endpoint name can not be empty')
        run = cleaned_data.get("Run")
        run_endpoint_name = cleaned_data.get("RunEndpointName")
        if run_endpoint_name == '' and run != None:
            self.add_error('RunEndpointName', 'If run is checked, analysis endpoint name can not be empty')
    
    entry_type_choices = [("analysis", "analysis"), ("biosample", "biosample"), ("cohort", "cohort"), ("dataset", "dataset"), ("genomicVariant", "genomicVariant"), ("individual", "individual"), ("run", "run")]
    granularity_choices = [
    ('boolean', 'Boolean'),
    ('count', 'Count'),
    ('record', 'Record'),
    ]
    database_choices=[(name, name) for name in os.listdir("/home/app/web/beacon/connections")]
    analysis_entry_type, analysis_endpoint_name, analysis_lookups =get_entry_types('analysis')
    biosample_entry_type, biosample_endpoint_name, biosample_lookups =get_entry_types('biosample')
    cohort_entry_type, cohort_endpoint_name, cohort_lookups =get_entry_types('cohort')
    dataset_entry_type, dataset_endpoint_name, dataset_lookups =get_entry_types('dataset')
    genomicVariant_entry_type, genomicVariant_endpoint_name, genomicVariant_lookups =get_entry_types('genomicVariant')
    individual_entry_type, individual_endpoint_name, individual_lookups =get_entry_types('individual')
    run_entry_type, run_endpoint_name, run_lookups =get_entry_types('run')
    Analysis = forms.BooleanField(required=False, help_text='/'+analysis_endpoint_name)
    AnalysisEndpointName = forms.CharField(required=False,help_text='Endpoint Name')
    AnalysisNonFiltered = forms.BooleanField(required=False, help_text='Analysis Non-Filtered Queries')
    analysis_choices=[]
    analysis_choices=generate_endpoints(analysis_choices, analysis_endpoint_name, biosample_endpoint_name, biosample_entry_type, analysis_lookups)
    analysis_choices=generate_endpoints(analysis_choices, analysis_endpoint_name, cohort_endpoint_name, cohort_entry_type, analysis_lookups)
    analysis_choices=generate_endpoints(analysis_choices, analysis_endpoint_name, dataset_endpoint_name, dataset_entry_type, analysis_lookups)
    analysis_choices=generate_endpoints(analysis_choices, analysis_endpoint_name, genomicVariant_endpoint_name, genomicVariant_entry_type, analysis_lookups)
    analysis_choices=generate_endpoints(analysis_choices, analysis_endpoint_name, individual_endpoint_name, individual_entry_type, analysis_lookups)
    analysis_choices=generate_endpoints(analysis_choices, analysis_endpoint_name, run_endpoint_name, run_entry_type, analysis_lookups)
    analysis_choices=generate_endpoints(analysis_choices, analysis_endpoint_name, analysis_endpoint_name, analysis_entry_type, analysis_lookups)
    AnalysisEndpoints = forms.MultipleChoiceField(
        choices=analysis_choices, 
        widget=forms.CheckboxSelectMultiple
    )
    analysis_granularity= forms.ChoiceField(
        widget=forms.RadioSelect,
        choices=granularity_choices, 
    )
    analysis_engine= forms.ChoiceField(choices=database_choices, help_text="Database Engine")
    Biosample = forms.BooleanField(required=False, help_text='/'+biosample_endpoint_name)
    BiosampleEndpointName = forms.CharField(required=False,help_text='Endpoint Name')
    BiosampleNonFiltered = forms.BooleanField(required=False, help_text='Biosample Non-Filtered Queries')
    biosample_choices=[]
    biosample_choices=generate_endpoints(biosample_choices, biosample_endpoint_name, analysis_endpoint_name, analysis_entry_type, biosample_lookups)
    biosample_choices=generate_endpoints(biosample_choices, biosample_endpoint_name, cohort_endpoint_name, cohort_entry_type, biosample_lookups)
    biosample_choices=generate_endpoints(biosample_choices, biosample_endpoint_name, dataset_endpoint_name, dataset_entry_type, biosample_lookups)
    biosample_choices=generate_endpoints(biosample_choices, biosample_endpoint_name, genomicVariant_endpoint_name, genomicVariant_entry_type, biosample_lookups)
    biosample_choices=generate_endpoints(biosample_choices, biosample_endpoint_name, individual_endpoint_name, individual_entry_type, biosample_lookups)
    biosample_choices=generate_endpoints(biosample_choices, biosample_endpoint_name, run_endpoint_name, run_entry_type, biosample_lookups)
    biosample_choices=generate_endpoints(biosample_choices, biosample_endpoint_name, biosample_endpoint_name, biosample_entry_type, biosample_lookups)
    BiosampleEndpoints = forms.MultipleChoiceField(
        choices=biosample_choices, 
        widget=forms.CheckboxSelectMultiple
    )
    biosample_granularity= forms.ChoiceField(
        widget=forms.RadioSelect,
        choices=granularity_choices, 
    )
    biosample_engine= forms.ChoiceField(choices=database_choices, help_text="Database Engine")
    Cohort = forms.BooleanField(required=False, help_text='/'+cohort_endpoint_name)
    CohortEndpointName = forms.CharField(required=False,help_text='Endpoint Name')
    CohortNonFiltered = forms.BooleanField(required=False, help_text='Cohort Non-Filtered Queries')
    cohort_choices=[]
    cohort_choices=generate_endpoints(cohort_choices, cohort_endpoint_name, analysis_endpoint_name, analysis_entry_type, cohort_lookups)
    cohort_choices=generate_endpoints(cohort_choices, cohort_endpoint_name, biosample_endpoint_name, biosample_entry_type, cohort_lookups)
    cohort_choices=generate_endpoints(cohort_choices, cohort_endpoint_name, dataset_endpoint_name, dataset_entry_type, cohort_lookups)
    cohort_choices=generate_endpoints(cohort_choices, cohort_endpoint_name, genomicVariant_endpoint_name, genomicVariant_entry_type, cohort_lookups)
    cohort_choices=generate_endpoints(cohort_choices, cohort_endpoint_name, individual_endpoint_name, individual_entry_type, cohort_lookups)
    cohort_choices=generate_endpoints(cohort_choices, cohort_endpoint_name, run_endpoint_name, run_entry_type, cohort_lookups)
    cohort_choices=generate_endpoints(cohort_choices, cohort_endpoint_name, cohort_endpoint_name, cohort_entry_type, cohort_lookups)
    CohortEndpoints = forms.MultipleChoiceField(
        choices=cohort_choices, 
        widget=forms.CheckboxSelectMultiple
    )
    cohort_granularity= forms.ChoiceField(
        widget=forms.RadioSelect,
        choices=granularity_choices, 
    )
    cohort_engine= forms.ChoiceField(choices=database_choices, help_text="Database Engine")
    Dataset = forms.BooleanField(required=False, help_text='/'+dataset_endpoint_name)
    DatasetEndpointName = forms.CharField(required=False,help_text='Endpoint Name')
    DatasetNonFiltered = forms.BooleanField(required=False, help_text='Dataset Non-Filtered Queries')
    dataset_choices=[]
    dataset_choices=generate_endpoints(dataset_choices, dataset_endpoint_name, analysis_endpoint_name, analysis_entry_type, dataset_lookups)
    dataset_choices=generate_endpoints(dataset_choices, dataset_endpoint_name, biosample_endpoint_name, biosample_entry_type, dataset_lookups)
    dataset_choices=generate_endpoints(dataset_choices, dataset_endpoint_name, cohort_endpoint_name, cohort_entry_type, dataset_lookups)
    dataset_choices=generate_endpoints(dataset_choices, dataset_endpoint_name, genomicVariant_endpoint_name, genomicVariant_entry_type, dataset_lookups)
    dataset_choices=generate_endpoints(dataset_choices, dataset_endpoint_name, individual_endpoint_name, individual_entry_type, dataset_lookups)
    dataset_choices=generate_endpoints(dataset_choices, dataset_endpoint_name, run_endpoint_name, run_entry_type, dataset_lookups)
    dataset_choices=generate_endpoints(dataset_choices, dataset_endpoint_name, dataset_endpoint_name, dataset_entry_type, dataset_lookups)
    DatasetEndpoints = forms.MultipleChoiceField(
        choices=dataset_choices, 
        widget=forms.CheckboxSelectMultiple
    )
    dataset_granularity= forms.ChoiceField(
        widget=forms.RadioSelect,
        choices=granularity_choices, 
    )
    dataset_engine= forms.ChoiceField(choices=database_choices, help_text="Database Engine")
    GenomicVariant = forms.BooleanField(required=False, help_text='/'+genomicVariant_endpoint_name)
    GenomicVariantEndpointName = forms.CharField(required=False,help_text='Endpoint Name')
    GenomicVariantNonFiltered = forms.BooleanField(required=False, help_text='Genomic Variant Non-Filtered Queries')
    genomicVariant_choices=[]
    genomicVariant_choices=generate_endpoints(genomicVariant_choices, genomicVariant_endpoint_name, analysis_endpoint_name, analysis_entry_type, genomicVariant_lookups)
    genomicVariant_choices=generate_endpoints(genomicVariant_choices, genomicVariant_endpoint_name, biosample_endpoint_name, biosample_entry_type, genomicVariant_lookups)
    genomicVariant_choices=generate_endpoints(genomicVariant_choices, genomicVariant_endpoint_name, cohort_endpoint_name, cohort_entry_type, genomicVariant_lookups)
    genomicVariant_choices=generate_endpoints(genomicVariant_choices, genomicVariant_endpoint_name, dataset_endpoint_name, dataset_entry_type, genomicVariant_lookups)
    genomicVariant_choices=generate_endpoints(genomicVariant_choices, genomicVariant_endpoint_name, individual_endpoint_name, individual_entry_type, genomicVariant_lookups)
    genomicVariant_choices=generate_endpoints(genomicVariant_choices, genomicVariant_endpoint_name, run_endpoint_name, run_entry_type, genomicVariant_lookups)
    genomicVariant_choices=generate_endpoints(genomicVariant_choices, genomicVariant_endpoint_name, genomicVariant_endpoint_name, genomicVariant_entry_type, genomicVariant_lookups)
    GenomicVariantEndpoints = forms.MultipleChoiceField(
        choices=genomicVariant_choices, 
        widget=forms.CheckboxSelectMultiple
    )
    genomicVariation_granularity= forms.ChoiceField(
        widget=forms.RadioSelect,
        choices=granularity_choices, 
    )
    genomicVariation_engine= forms.ChoiceField(choices=database_choices, help_text="Database Engine")
    Individual = forms.BooleanField(required=False, help_text='/'+individual_endpoint_name)
    IndividualEndpointName = forms.CharField(required=False,help_text='Endpoint Name')
    IndividualNonFiltered = forms.BooleanField(required=False, help_text='Individual Non-Filtered Queries')
    individual_choices=[]
    individual_choices=generate_endpoints(individual_choices, individual_endpoint_name, analysis_endpoint_name, analysis_entry_type, individual_lookups)
    individual_choices=generate_endpoints(individual_choices, individual_endpoint_name, biosample_endpoint_name, biosample_entry_type, individual_lookups)
    individual_choices=generate_endpoints(individual_choices, individual_endpoint_name, cohort_endpoint_name, cohort_entry_type, individual_lookups)
    individual_choices=generate_endpoints(individual_choices, individual_endpoint_name, dataset_endpoint_name, dataset_entry_type, individual_lookups)
    individual_choices=generate_endpoints(individual_choices, individual_endpoint_name, genomicVariant_endpoint_name, genomicVariant_entry_type, individual_lookups)
    individual_choices=generate_endpoints(individual_choices, individual_endpoint_name, run_endpoint_name, run_entry_type, individual_lookups)
    individual_choices=generate_endpoints(individual_choices, individual_endpoint_name, individual_endpoint_name, individual_entry_type, individual_lookups)
    IndividualEndpoints = forms.MultipleChoiceField(
        choices=individual_choices, 
        widget=forms.CheckboxSelectMultiple
    )
    individual_granularity= forms.ChoiceField(
        widget=forms.RadioSelect,
        choices=granularity_choices, 
    )
    individual_engine= forms.ChoiceField(choices=database_choices, help_text="Database Engine")
    Run = forms.BooleanField(required=False, help_text='/'+run_endpoint_name)
    RunEndpointName = forms.CharField(required=False,help_text='Endpoint Name')
    RunNonFiltered = forms.BooleanField(required=False, help_text='Run Non-Filtered Queries')
    run_choices=[]
    run_choices=generate_endpoints(run_choices, run_endpoint_name, analysis_endpoint_name, analysis_entry_type, run_lookups)
    run_choices=generate_endpoints(run_choices, run_endpoint_name, biosample_endpoint_name, biosample_entry_type, run_lookups)
    run_choices=generate_endpoints(run_choices, run_endpoint_name, cohort_endpoint_name, cohort_entry_type, run_lookups)
    run_choices=generate_endpoints(run_choices, run_endpoint_name, dataset_endpoint_name, dataset_entry_type, run_lookups)
    run_choices=generate_endpoints(run_choices, run_endpoint_name, genomicVariant_endpoint_name, genomicVariant_entry_type, run_lookups)
    run_choices=generate_endpoints(run_choices, run_endpoint_name, individual_endpoint_name, individual_entry_type, run_lookups)
    run_choices=generate_endpoints(run_choices, run_endpoint_name, run_endpoint_name, run_entry_type, run_lookups)
    RunEndpoints = forms.MultipleChoiceField(
        choices=run_choices, 
        widget=forms.CheckboxSelectMultiple
    )
    run_granularity= forms.ChoiceField(
        widget=forms.RadioSelect,
        choices=granularity_choices, 
    )
    run_engine= forms.ChoiceField(choices=database_choices, help_text="Database Engine")