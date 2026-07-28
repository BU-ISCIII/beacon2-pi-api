import obonet
import networkx
import os
import gc
import urllib.request
from urllib.error import HTTPError
import progressbar
from beacon.connections.mongo.client import get_client

# to support different paths for admin-ui and beaconprod
ONTOLOGIES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ontologies")


ONTOLOGY_URLS = {
    "ENSGLOSSARY": "https://raw.githubusercontent.com/Ensembl/ensembl-glossary/master/ensembl-glossary.obo",
    "EFO": "https://www.ebi.ac.uk/efo/efo.obo",
}


class MyProgressBar:
    def __init__(self):
        self.pbar = None

    def __call__(self, block_num: int, block_size: int, total_size: int):
        if not self.pbar:
            self.pbar = progressbar.ProgressBar(maxval=total_size)
            self.pbar.start()

        downloaded = block_num * block_size
        if downloaded < total_size:
            self.pbar.update(downloaded)
        else:
            self.pbar.finish()

def load_ontology(ontology_id: str):
    if ontology_id.isalpha():
        print(ontology_id)
        url_alt = "https://www.ebi.ac.uk/efo/efo.obo"
        url = ONTOLOGY_URLS.get(
            ontology_id.upper(),
            "http://purl.obolibrary.org/obo/{}.obo".format(ontology_id.lower()),
        )
        path = os.path.join(ONTOLOGIES_DIR, "{}.obo".format(ontology_id.lower()))

        try:
            if not os.path.exists(path):
                full_path = os.path.realpath(__file__)
                print(full_path)
                urllib.request.urlretrieve(url, path, MyProgressBar())
        except HTTPError:
            # TODO: Handle error in case the HTTP address could not be reached.
            pass
        except ValueError:
            # TODO: Handle error in case there was a wrong ontology trying to be mapped.
            pass
        except Exception:
            pass
        try:
            if os.stat(path).st_size == 0:
                try:
                    urllib.request.urlretrieve(url_alt, path, MyProgressBar())
                except HTTPError:
                    # TODO: Handle error in case the HTTP address could not be reached.
                    pass
                except ValueError:
                    # TODO: Handle error in case there was a wrong ontology trying to be mapped.
                    pass
        except Exception:
                pass
    return '{}'.format(ontology_id)


def get_descendants_and_similarities():
    client=get_client()
    try:
        client['beacon'].drop_collection("similarities")
    except Exception:
        client['beacon'].create_collection(name="similarities")
    try:
        client['beacon'].validate_collection("similarities")
    except Exception:
        db=client['beacon'].create_collection(name="similarities")
    filtering_docs=client['beacon'].filtering_terms.find({"type": "ontology"})
    ontologies_by_prefix={}
    for ft_doc in filtering_docs:
        prefix = ft_doc["id"].split(':')[0]
        if ft_doc["id"] not in ontologies_by_prefix.setdefault(prefix, []):
            ontologies_by_prefix[prefix].append(ft_doc["id"])

    for prefix, ontology_ids in ontologies_by_prefix.items():
        load_ontology(prefix)
        url = os.path.join(ONTOLOGIES_DIR, "{}.obo".format(prefix.lower()))
        url_alt = "https://www.ebi.ac.uk/efo/efo.obo"
        try:
            graph = obonet.read_obo(url)
        except Exception:
            try:
                graph = obonet.read_obo(url_alt)
            except Exception as exc:
                print("Skipping {}: {}".format(prefix, exc))
                continue

        for ontology in ontology_ids:
            list_of_cousins = []
            list_of_brothers = []
            list_of_uncles = []
            list_of_grandpas = []
            try:
                descendants = networkx.ancestors(graph, ontology)
            except Exception:
                descendants = ''
            descendants=list(descendants)

            print(descendants)

            try:
                tree = [n for n in graph.successors(ontology)]
                for onto in tree:
                    predecessors = [n for n in graph.successors(onto)]
                    successors = [n for n in graph.predecessors(onto)]
                    list_of_brothers.append(successors)
                    list_of_grandpas.append(predecessors)
                similarity_high=[]
                similarity_medium=[]
                similarity_low=[]
                for llista in list_of_grandpas:
                    for item in llista:
                        uncles = [n for n in graph.predecessors(item)]
                        list_of_uncles.append(uncles)
                        for uncle in uncles:
                            cousins = [n for n in graph.predecessors(uncle)]
                            if ontology not in cousins:
                                list_of_cousins.append(cousins)

                for llista in list_of_brothers:
                    for item in llista:
                        similarity_high.append(item)
                        similarity_medium.append(item)
                        similarity_low.append(item)

                for llista in list_of_cousins:
                    for item in llista:
                        similarity_medium.append(item)
                        similarity_low.append(item)

                for llista in list_of_uncles:
                    for item in llista:
                        similarity_low.append(item)

            except Exception:
                similarity_high=[]
                similarity_medium=[]
                similarity_low=[]

            dict={}
            dict['id']=ontology
            dict['descendants']=descendants
            dict['similarity_high']=similarity_high
            dict['similarity_medium']=similarity_medium
            dict['similarity_low']=similarity_low

            client['beacon'].similarities.insert_one(dict)
            print("succesfully retrieved descendants from {}".format(ontology))

        del graph
        gc.collect()


get_descendants_and_similarities()
