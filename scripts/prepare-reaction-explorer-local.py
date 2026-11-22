#!/usr/bin/env python3
"""Initialize and load only the local deployment warehouse before GitOps publication."""
import argparse
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def password(filename):
    path = Path(filename).expanduser().resolve()
    if subprocess.run(['git', '-C', str(path.parent), 'rev-parse', '--is-inside-work-tree'],
                      capture_output=True).returncode == 0:
        raise ValueError('Keep credentials outside Git working trees')
    if path.stat().st_mode & 0o077:
        raise ValueError('Password files require chmod 600')
    value = path.read_text().strip()
    if not value or '\n' in value or '\r' in value:
        raise ValueError('Password must be nonempty and one line')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--environment', required=True, choices=['local'])
    parser.add_argument('--app-dir', required=True, type=Path)
    parser.add_argument('--password-file', required=True)
    parser.add_argument('--dashboard-password-file', required=True)
    args = parser.parse_args()
    app = args.app_dir.resolve()
    if not (app / 'pipeline/dbt/profiles.yml').is_file():
        parser.error('--app-dir must be the reaction-explorer source checkout')
    env = dict(os.environ, WAREHOUSE_PORT='5433', DASHBOARD_DB_HOST='127.0.0.1',
               DBT_SCHEMA='analytics', WAREHOUSE_PASSWORD=password(args.password_file),
               DASHBOARD_PASSWORD=password(args.dashboard_password_file))
    schema = str(ROOT / 'apps/reaction-explorer/schema.sql')
    initialize = '''import sys
import psycopg
from pipeline.warehouse import connect
try:
    with connect() as conn:
        with conn.transaction():
            conn.execute(open(sys.argv[1]).read())
except psycopg.Error:
    raise SystemExit('Schema preparation failed; check deployment credentials and privileges.') from None
'''
    commands = [
        ['uv', 'sync', '--locked'],
        ['./scripts/check-workbook.sh'],
        ['uv', 'run', '--locked', 'python', '-c', initialize, schema],
        ['uv', 'run', '--locked', 'python', '-m', 'pipeline.warehouse'],
        ['uv', 'run', '--locked', 'dbt', 'build', '--project-dir', 'pipeline/dbt',
         '--profiles-dir', 'pipeline/dbt'],
        ['uv', 'run', '--locked', 'python', '-m', 'pipeline.check_comparisons'],
        ['uv', 'run', '--locked', 'python', '-m', 'backend.check_dashboard'],
    ]
    for command in commands:
        subprocess.run(command, cwd=app, env=env, check=True)
    print('Deployment warehouse prepared and pinned data reconciled; Pod connectivity remains separate.')


if __name__ == '__main__':
    main()
