"""Check environment isolation, external databases and selected release images."""
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


for env in ('local', 'aws'):
    resources = render(f'apps/demo-api/overlays/{env}')
    assert resources['ConfigMap', 'demo-api-config']['data']['APP_MESSAGE'] == 'Hello from FastAPI!'
    deployment = resources['Deployment', 'demo-api']
    migration = resources['Job', 'demo-api-migrate']
    api_image = deployment['spec']['template']['spec']['containers'][0]['image']
    job_image = migration['spec']['template']['spec']['containers'][0]['image']
    assert api_image == job_image, f'{env}: API and migration must use the same release'
    assert migration['metadata']['annotations']['argocd.argoproj.io/hook'] == 'Sync'
    ingress = resources['Ingress', 'demo-api']
    assert ingress['spec']['ingressClassName'] == ('traefik' if env == 'local' else 'alb')
    if env == 'local':
        assert not any(kind in ('PersistentVolume', 'PersistentVolumeClaim', 'StatefulSet') for kind, name in resources), 'Local app sync must not provision database/storage'
        assert ('Service', 'myfastapiapp-postgres-service') not in resources
        assert not any('rds-ca' in name for kind, name in resources)
    else:
        assert not any('mailpit' in name for kind, name in resources), 'AWS must not deploy the local email inbox'
        assert not any(kind in ('PersistentVolume', 'PersistentVolumeClaim', 'StatefulSet') for kind, name in resources), 'AWS must not deploy local database/storage'
        pod = deployment['spec']['template']['spec']
        settings = {v['name']: v.get('value') for v in pod['containers'][0]['env']}
        assert settings.get('AUTH_SMTP_HOST') != 'demo-api-mailpit', 'AWS must not send mail to the local test inbox'
        assert settings['PGSSLMODE'] == 'verify-full'
        assert pod['securityContext']['runAsNonRoot'] is True
    registrations = render(f'argocd/{env}')
    assert set(registrations) == {('ApplicationSet', 'apps')}
    appset = registrations['ApplicationSet', 'apps']
    assert appset['metadata']['namespace'] == 'argocd'
    assert appset['spec']['syncPolicy']['preserveResourcesOnDeletion'] is True
    template = appset['spec']['template']['spec']
    assert template['source']['path'] == '{{.path.path}}'
    assert template['destination']['namespace'] == '{{index .path.segments 1}}'
    generator = appset['spec']['generators'][0]['git']
    assert generator['directories'] == [{'path': f'apps/*/overlays/{env}'}]
    assert generator['repoURL'] == template['source']['repoURL']
    root = json.loads(subprocess.check_output(
        ['kubectl', 'patch', '--local', '-f', str(ROOT / 'bootstrap' / f'{env}.yaml'),
         '--type=merge', '-p', '{}', '-o', 'json'], text=True))
    assert root['metadata']['name'] == 'bootstrap'
    assert root['metadata']['namespace'] == 'argocd'
    assert 'environment' not in root['metadata'].get('labels', {})
    assert root['spec']['syncPolicy']['automated']['enabled'] is True
    assert root['spec']['source']['path'] == f'argocd/{env}'
    assert root['spec']['source']['repoURL'] == generator['repoURL']
    assert appset['spec']['template']['metadata']['name'] == '{{index .path.segments 1}}'
    assert 'environment' not in appset['spec']['template']['metadata'].get('labels', {})
    assert bool(template['syncPolicy'].get('automated')) == (env == 'local')
print('Rendered environment isolation, external database and image consistency checks passed.')
