"""Aplica (ou verifica) as atribuicoes de FlexiPage dos apps Lightning por BU.

Fonte unica: scripts/apps/atribuicoes-flexipage.csv
  colunas: app,objeto,tipo,recordType,perfil,formFactor,pagina
  tipo APP_DEFAULT  -> <actionOverrides> (View por objeto; Tab para standard-home)
  tipo RT_PERFIL    -> <profileActionOverrides> (View por RT x perfil x formFactor)

Modo padrao: reescreve SO os blocos <actionOverrides> e <profileActionOverrides>
dos 4 apps (ADV, SOL, Arnone, Arnone_Atendimento); todo o resto do XML fica
como esta, byte a byte.

Modo --verificar: compara o XML com o CSV (como conjuntos, sem depender da
ordem que a org devolve no retrieve) e sai com codigo 1 se divergir.

Uso (rodar com python -I):
  python -I scripts/apps/aplicar-atribuicoes.py
  python -I scripts/apps/aplicar-atribuicoes.py --verificar
  python -I scripts/apps/aplicar-atribuicoes.py --verificar --dir <pasta com .app ou .app-meta.xml>

Card: APPS-POR-BU.
"""
import argparse
import csv
import os
import re
import sys
import xml.etree.ElementTree as ET

APPS = ['ADV', 'SOL', 'Arnone', 'Arnone_Atendimento']
NS = '{http://soap.sforce.com/2006/04/metadata}'
AQUI = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.normpath(os.path.join(AQUI, '..', '..'))
CSV_PADRAO = os.path.join(AQUI, 'atribuicoes-flexipage.csv')
DIR_PADRAO = os.path.join(RAIZ, 'force-app', 'main', 'default', 'applications')
IND = '    '


def ler_csv(caminho):
    por_app = {a: {'APP_DEFAULT': [], 'RT_PERFIL': []} for a in APPS}
    with open(caminho, encoding='utf-8', newline='') as f:
        for i, l in enumerate(csv.DictReader(f), start=2):
            if l['app'] not in por_app or l['tipo'] not in ('APP_DEFAULT', 'RT_PERFIL'):
                sys.exit('CSV linha %d invalida: %r' % (i, l))
            if l['tipo'] == 'RT_PERFIL' and not (l['recordType'] and l['perfil']):
                sys.exit('CSV linha %d: RT_PERFIL sem recordType/perfil' % i)
            por_app[l['app']][l['tipo']].append(l)
    return por_app


def bloco_action(l):
    acao = 'Tab' if l['objeto'] == 'standard-home' else 'View'
    return (IND + '<actionOverrides>\n'
            + IND * 2 + '<actionName>%s</actionName>\n' % acao
            + IND * 2 + '<content>%s</content>\n' % l['pagina']
            + IND * 2 + '<formFactor>%s</formFactor>\n' % l['formFactor']
            + IND * 2 + '<skipRecordTypeSelect>false</skipRecordTypeSelect>\n'
            + IND * 2 + '<type>Flexipage</type>\n'
            + IND * 2 + '<pageOrSobjectType>%s</pageOrSobjectType>\n' % l['objeto']
            + IND + '</actionOverrides>\n')


def bloco_profile(l):
    return (IND + '<profileActionOverrides>\n'
            + IND * 2 + '<actionName>View</actionName>\n'
            + IND * 2 + '<content>%s</content>\n' % l['pagina']
            + IND * 2 + '<formFactor>%s</formFactor>\n' % l['formFactor']
            + IND * 2 + '<pageOrSobjectType>%s</pageOrSobjectType>\n' % l['objeto']
            + IND * 2 + '<recordType>%s</recordType>\n' % l['recordType']
            + IND * 2 + '<type>Flexipage</type>\n'
            + IND * 2 + '<profile>%s</profile>\n' % l['perfil']
            + IND + '</profileActionOverrides>\n')


def arquivo_app(pasta, app):
    for nome in (app + '.app-meta.xml', app + '.app'):
        p = os.path.join(pasta, nome)
        if os.path.exists(p):
            return p
    sys.exit('App %s nao encontrado em %s' % (app, pasta))


def aplicar(pasta, por_app):
    for app in APPS:
        p = arquivo_app(pasta, app)
        with open(p, encoding='utf-8', newline='') as f:
            t = f.read()
        for tag in ('actionOverrides', 'profileActionOverrides'):
            t = re.sub(r'[ \t]*<%s>.*?</%s>\r?\n' % (tag, tag), '', t, flags=re.S)
        novos_a = ''.join(bloco_action(l) for l in por_app[app]['APP_DEFAULT'])
        novos_p = ''.join(bloco_profile(l) for l in por_app[app]['RT_PERFIL'])
        # actionOverrides e o primeiro elemento do CustomApplication (ordem alfabetica do schema)
        t, n1 = re.subn(r'(<CustomApplication[^>]*>\r?\n)', lambda m: m.group(1) + novos_a, t, count=1)
        # profileActionOverrides vem logo depois de navType
        t, n2 = re.subn(r'([ \t]*<navType>[^<]*</navType>\r?\n)', lambda m: m.group(1) + novos_p, t, count=1)
        if n1 != 1 or n2 != 1:
            sys.exit('%s: nao achei <CustomApplication> ou <navType> para ancorar' % p)
        with open(p, 'w', encoding='utf-8', newline='') as f:
            f.write(t)
        print('%-20s actionOverrides=%d profileActionOverrides=%d' % (
            app, len(por_app[app]['APP_DEFAULT']), len(por_app[app]['RT_PERFIL'])))


def chave_action(l):
    return ('Tab' if l['objeto'] == 'standard-home' else 'View', l['objeto'], l['formFactor'], l['pagina'])


def chave_profile(l):
    return (l['objeto'], l['recordType'], l['perfil'], l['formFactor'], l['pagina'])


def txt(e, tag):
    x = e.find(NS + tag)
    return x.text if x is not None else ''


def verificar(pasta, por_app):
    ok = True
    for app in APPS:
        raiz = ET.parse(arquivo_app(pasta, app)).getroot()
        tem_a = sorted((txt(e, 'actionName'), txt(e, 'pageOrSobjectType'), txt(e, 'formFactor'), txt(e, 'content'))
                       for e in raiz.findall(NS + 'actionOverrides'))
        tem_p = sorted((txt(e, 'pageOrSobjectType'), txt(e, 'recordType'), txt(e, 'profile'), txt(e, 'formFactor'), txt(e, 'content'))
                       for e in raiz.findall(NS + 'profileActionOverrides'))
        quer_a = sorted(chave_action(l) for l in por_app[app]['APP_DEFAULT'])
        quer_p = sorted(chave_profile(l) for l in por_app[app]['RT_PERFIL'])
        for nome, tem, quer in (('actionOverrides', tem_a, quer_a), ('profileActionOverrides', tem_p, quer_p)):
            if tem != quer:
                ok = False
                print('DIVERGE %s %s: xml=%d csv=%d' % (app, nome, len(tem), len(quer)))
                for x in sorted(set(quer) - set(tem)):
                    print('   falta no XML :', x)
                for x in sorted(set(tem) - set(quer)):
                    print('   sobra no XML :', x)
            else:
                print('OK      %-20s %-24s %d' % (app, nome, len(tem)))
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--verificar', action='store_true')
    ap.add_argument('--dir', default=DIR_PADRAO)
    ap.add_argument('--csv', default=CSV_PADRAO)
    a = ap.parse_args()
    por_app = ler_csv(a.csv)
    if a.verificar:
        sys.exit(0 if verificar(a.dir, por_app) else 1)
    aplicar(a.dir, por_app)


if __name__ == '__main__':
    main()
