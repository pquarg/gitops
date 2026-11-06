"""Check environment isolation and retained data identities in rendered resources."""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def render(path):
    stream = subprocess.check_output(
        ['kubectl', 'patch', '--local', '-k', str(ROOT / path),
         '--type=merge', '-p', '{}', '-o', 'json'], text=True
    ).lstrip()
    decoder = json.JSONDecoder()
    resources = []
    while stream:
        obj, end = decoder.raw_decode(stream)
        resources.extend(obj['items'] if obj.get('kind') == 'List' else [obj])
        stream = stream[end:].lstrip()
    return {(r['kind'], r['metadata']['name']): r for r in resources}


for env, prefix in [('local', 'staging'), ('aws', 'aws')]:
    resources = render(f'apps/myfastapiapp/overlays/{env}')
    deployment = resources['Deployment', 'myfastapiapp-deployment']
    migration = resources['Job', 'myfastapiapp-migrate']
    api_image = deployment['spec']['template']['spec']['containers'][0]['image']
    job_image = migration['spec']['template']['spec']['containers'][0]['image']
    assert api_image == job_image, f'{env}: API and migration must use the same release'
    assert migration['metadata']['annotations']['argocd.argoproj.io/hook'] == 'Sync'
    ingress = resources['Ingress', 'myfastapiapp-ingress']
    assert ingress['spec']['ingressClassName'] == ('traefik' if env == 'local' else 'alb')
    if env == 'local':
        pv = resources['PersistentVolume', 'myfastapiapp-postgres-pv']
        assert pv['spec']['local']['path'] == '/mnt/myfastapiapp-postgres'
        assert pv['spec']['claimRef']['namespace'] == 'myfastapiapp'
        assert pv['spec']['persistentVolumeReclaimPolicy'] == 'Retain'
        assert pv['metadata']['annotations']['argocd.argoproj.io/sync-options'] == 'Prune=false,Delete=false'
        assert ('StatefulSet', 'myfastapiapp-postgres-statefulset') in resources
        assert not any('rds-ca' in name for kind, name in resources)
    else:
        assert not any(kind in ('PersistentVolume', 'PersistentVolumeClaim', 'StatefulSet') for kind, name in resources), 'AWS must not deploy local database/storage'
        pod = deployment['spec']['template']['spec']
        settings = {v['name']: v.get('value') for v in pod['containers'][0]['env']}
        assert settings['PGSSLMODE'] == 'verify-full'
        assert pod['securityContext']['runAsNonRoot'] is True
    registrations = render(f'argocd/{env}')
    appset = registrations['ApplicationSet', f'{prefix}-apps']
    assert appset['spec']['syncPolicy']['preserveResourcesOnDeletion'] is True
    template = appset['spec']['template']['spec']
    assert template['source']['path'] == '{{.path.path}}'
    assert template['destination']['namespace'] == '{{index .path.segments 1}}'
    generator = appset['spec']['generators'][0]['git']
    assert generator['directories'] == [{'path': f'apps/*/overlays/{env}'}]
    assert generator['repoURL'] == template['source']['repoURL']
    root_file = 'staging.yaml' if env == 'local' else 'aws.yaml'
    root = json.loads(subprocess.check_output(
        ['kubectl', 'patch', '--local', '-f', str(ROOT / 'root' / root_file),
         '--type=merge', '-p', '{}', '-o', 'json'], text=True))
    assert root['metadata']['name'] == f'{prefix}-root'
    assert root['spec']['source']['path'] == f'argocd/{env}'
    assert root['spec']['source']['repoURL'] == generator['repoURL']
    assert appset['spec']['template']['metadata']['name'] == prefix + '-{{index .path.segments 1}}'
    assert bool(template['syncPolicy'].get('automated')) == (env == 'local')
print('Rendered environment isolation, image consistency and retained storage checks passed.')
