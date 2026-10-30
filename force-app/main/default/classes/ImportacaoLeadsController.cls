/**
 * Importação de leads — orquestração da importação multi-BU a partir de um
 * arquivo. Substitui o SOLEnriquecimentoController.
 *
 * Consumido pelo LWC importacaoLeads. O parse do arquivo, o diagnóstico e o
 * mapeamento das colunas acontecem no cliente; aqui o servidor:
 *  - lista as BUs e os perfis (Perfil_Importacao__mdt) ativos que o usuário pode
 *    usar (custom permission do perfil);
 *  - persiste o lote e as linhas;
 *  - classifica o casamento pela chave do perfil (CNPJ ou CPF), só entre leads
 *    do Record Type do perfil;
 *  - aceita a confirmação do operador e enfileira o ImportacaoLeadsBatch.
 *
 * Segurança: iniciarLote, adicionarLinhas, classificar e confirmar exigem a
 * custom permission do perfil e o perfil ativo (FeatureManagement.checkPermission),
 * e lançam exceção caso contrário. `with sharing`: o casamento respeita o
 * compartilhamento do operador. Chaves sempre em BIND, nunca concatenadas. A FLS
 * de Lead é imposta na gravação, pelo stripInaccessible do batch.
 */
public with sharing class ImportacaoLeadsController {
  public static final String MODO_DISTRIBUICAO_SOL = 'DISTRIBUICAO_SOL';
  public static final String MODO_REGRA_ATRIBUICAO = 'REGRA_ATRIBUICAO';

  /** Teto padrão quando o perfil não define Max_Linhas__c. */
  @TestVisible
  private static final Integer MAX_LINHAS_PADRAO = 5000;

  /** Chunk de gravação das linhas classificadas, para limitar heap. */
  private static final Integer CHUNK_UPDATE = 500;

  /** Amostra por balde devolvida à revisão (os MATCH_MULTIPLO vão inteiros). */
  private static final Integer AMOSTRA_POR_BALDE = 200;

  /** Teto de linhas MATCH_MULTIPLO devolvidas para escolha interativa. */
  private static final Integer MAX_MULTIPLO_RETORNO = 500;

  @TestVisible
  private static final String MSG_STE_SEM_MATCH = 'Lead não encontrado ou sem acesso; este perfil não cria leads.';
  @TestVisible
  private static final String MSG_JA_CONTATO = 'Já é contato (aluno ou candidato convertido).';

  public class ImportacaoException extends Exception {
  }

  // ==================================================================
  //  DTOs
  // ==================================================================

  public class BuDTO {
    @AuraEnabled
    public String value;
    @AuraEnabled
    public String label;
  }

  public class MapeamentoDTO {
    @AuraEnabled
    public String coluna;
    @AuraEnabled
    public String campoLead;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String politica;
    @AuraEnabled
    public Boolean usarNaCriacao;
    @AuraEnabled
    public String tipoConversao;
    @AuraEnabled
    public Decimal ordem;
  }

  public class PerfilDTO {
    @AuraEnabled
    public String developerName;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String descricao;
    @AuraEnabled
    public String bu;
    @AuraEnabled
    public String chave;
    @AuraEnabled
    public String layout;
    @AuraEnabled
    public String modoDono;
    @AuraEnabled
    public Boolean criarSemMatch;
    @AuraEnabled
    public String colunaChave;
    @AuraEnabled
    public String colunaCompany;
    @AuraEnabled
    public String colunaLastName;
    @AuraEnabled
    public Integer maxLinhas;
    @AuraEnabled
    public List<MapeamentoDTO> mapeamentos = new List<MapeamentoDTO>();
  }

  public class LinhaDTO {
    @AuraEnabled
    public Integer numeroLinha;
    @AuraEnabled
    public String chave;
    // campoLeadApiName -> valor de texto bruto (inclui Company/LastName).
    @AuraEnabled
    public Map<String, String> valores;
  }

  public class LeadAlvoDTO {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String nome;
    @AuraEnabled
    public String empresa;
    @AuraEnabled
    public String owner;
    @AuraEnabled
    public Boolean selecionado;
  }

  public class LinhaPreviewDTO {
    @AuraEnabled
    public Id linhaId;
    @AuraEnabled
    public Integer numeroLinha;
    @AuraEnabled
    public String chaveOriginal;
    @AuraEnabled
    public String chaveNormalizada;
    @AuraEnabled
    public String resultadoMatch;
    @AuraEnabled
    public String motivoInvalido;
    @AuraEnabled
    public String acao;
    @AuraEnabled
    public String resumo;
    @AuraEnabled
    public List<LeadAlvoDTO> leadsAlvo = new List<LeadAlvoDTO>();
  }

  public class PreviewDTO {
    @AuraEnabled
    public Id loteId;
    @AuraEnabled
    public String loteNome;
    @AuraEnabled
    public String perfil;
    @AuraEnabled
    public String modoDono;
    @AuraEnabled
    public Boolean criarSemMatch;
    @AuraEnabled
    public String chave;
    @AuraEnabled
    public Integer total = 0;
    @AuraEnabled
    public Integer matchUnico = 0;
    @AuraEnabled
    public Integer matchMultiplo = 0;
    @AuraEnabled
    public Integer semMatch = 0;
    @AuraEnabled
    public Integer convertido = 0;
    @AuraEnabled
    public Integer jaContato = 0;
    @AuraEnabled
    public Integer invalido = 0;
    @AuraEnabled
    public Integer duplicado = 0;
    @AuraEnabled
    public List<LinhaPreviewDTO> multiplos = new List<LinhaPreviewDTO>();
    @AuraEnabled
    public List<LinhaPreviewDTO> amostra = new List<LinhaPreviewDTO>();
  }

  public class SelecaoDTO {
    @AuraEnabled
    public Id linhaId;
    @AuraEnabled
    public String acao;
    @AuraEnabled
    public List<Id> leadsSelecionados;
  }

  public class StatusDTO {
    @AuraEnabled
    public Id loteId;
    @AuraEnabled
    public String loteNome;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String jobStatus;
    @AuraEnabled
    public Integer jobItensProcessados = 0;
    @AuraEnabled
    public Integer jobItensTotal = 0;
    @AuraEnabled
    public Integer qtdLinhas = 0;
    @AuraEnabled
    public Integer qtdAtualizados = 0;
    @AuraEnabled
    public Integer qtdCriados = 0;
    @AuraEnabled
    public Integer qtdMultiplos = 0;
    @AuraEnabled
    public Integer qtdSemMatch = 0;
    @AuraEnabled
    public Integer qtdConvertidos = 0;
    @AuraEnabled
    public Integer qtdInvalidos = 0;
    @AuraEnabled
    public Integer qtdIgnorados = 0;
    @AuraEnabled
    public Integer qtdErros = 0;
    @AuraEnabled
    public String mensagens;
  }

  // ==================================================================
  //  Perfis (CMDT) — com costura de teste
  // ==================================================================

  /**
   * Costura de teste: CMDT não aceita DML. Os testes injetam perfis (ex.: ESG
   * ativo) e matrizes determinísticas; o que é injetado sobrepõe o CMDT real.
   */
  @TestVisible
  private static Map<String, Perfil_Importacao__mdt> perfisOverride;
  @TestVisible
  private static Map<String, List<Perfil_Importacao_Campo__mdt>> camposOverride;

  private static Map<String, Perfil_Importacao__mdt> perfisCache;

  /** Todos os perfis, por DeveloperName (CMDT real + injetados em teste). */
  public static Map<String, Perfil_Importacao__mdt> perfis() {
    if (perfisCache == null) {
      perfisCache = new Map<String, Perfil_Importacao__mdt>();
      // SOQL (não getAll) para trazer o Long Text Descricao__c inteiro.
      for (Perfil_Importacao__mdt p : [
        SELECT
          DeveloperName,
          MasterLabel,
          BU__c,
          Record_Type__c,
          Unidade_Origem__c,
          Chave_Casamento__c,
          Layout_Arquivo__c,
          Modo_Dono__c,
          Permissao_Customizada__c,
          Criar_Sem_Match__c,
          Coluna_Chave__c,
          Coluna_Company__c,
          Coluna_LastName__c,
          Max_Linhas__c,
          Ordem__c,
          Ativo__c,
          Descricao__c
        FROM Perfil_Importacao__mdt
        ORDER BY Ordem__c ASC NULLS LAST
      ]) {
        perfisCache.put(p.DeveloperName, p);
      }
    }
    Map<String, Perfil_Importacao__mdt> saida = perfisCache.clone();
    if (perfisOverride != null) {
      saida.putAll(perfisOverride);
    }
    return saida;
  }

  /** Perfil por DeveloperName, sem checar permissão (uso do batch). */
  public static Perfil_Importacao__mdt perfil(String developerName) {
    Perfil_Importacao__mdt p = String.isBlank(developerName)
      ? null
      : perfis().get(developerName);
    if (p == null) {
      throw new ImportacaoException(
        'Perfil de importação não encontrado: ' + developerName + '.'
      );
    }
    return p;
  }

  /** True quando o perfil está ativo e o usuário tem a custom permission dele. */
  public static Boolean podeUsar(Perfil_Importacao__mdt p) {
    return p != null &&
      p.Ativo__c == true &&
      String.isNotBlank(p.Permissao_Customizada__c) &&
      FeatureManagement.checkPermission(p.Permissao_Customizada__c);
  }

  /** Perfil validado para o usuário corrente; lança se inativo ou sem permissão. */
  @TestVisible
  private static Perfil_Importacao__mdt perfilAutorizado(String developerName) {
    Perfil_Importacao__mdt p = perfil(developerName);
    if (p.Ativo__c != true) {
      throw new ImportacaoException(
        'O perfil de importação "' + p.MasterLabel + '" está inativo.'
      );
    }
    if (
      String.isBlank(p.Permissao_Customizada__c) ||
      !FeatureManagement.checkPermission(p.Permissao_Customizada__c)
    ) {
      throw new ImportacaoException(
        'Você não tem permissão para usar o perfil de importação "' +
          p.MasterLabel +
          '".'
      );
    }
    return p;
  }

  /** Mapeamentos ativos do perfil, ordenados por Ordem__c. */
  public static List<Perfil_Importacao_Campo__mdt> camposDoPerfil(
    String developerName
  ) {
    if (camposOverride != null && camposOverride.containsKey(developerName)) {
      return camposOverride.get(developerName);
    }
    return [
      SELECT
        DeveloperName,
        Coluna_Arquivo__c,
        Campo_Lead__c,
        Politica__c,
        Tipo_Conversao__c,
        Usar_Na_Criacao__c,
        Ordem__c,
        Ativo__c
      FROM Perfil_Importacao_Campo__mdt
      WHERE Perfil__r.DeveloperName = :developerName AND Ativo__c = TRUE
      ORDER BY Ordem__c ASC NULLS LAST
    ];
  }

  /** Mapeamentos ativos do perfil por API name do campo de Lead. */
  public static Map<String, Perfil_Importacao_Campo__mdt> matrizPorCampo(
    String developerName
  ) {
    Map<String, Perfil_Importacao_Campo__mdt> porCampo = new Map<String, Perfil_Importacao_Campo__mdt>();
    for (Perfil_Importacao_Campo__mdt m : camposDoPerfil(developerName)) {
      if (m.Ativo__c == true && String.isNotBlank(m.Campo_Lead__c)) {
        porCampo.put(m.Campo_Lead__c, m);
      }
    }
    return porCampo;
  }

  // ==================================================================
  //  BUs e perfis visíveis ao usuário
  // ==================================================================

  @AuraEnabled(cacheable=true)
  public static List<BuDTO> getBus() {
    try {
      Map<String, String> rotulos = rotulosBu();
      List<BuDTO> saida = new List<BuDTO>();
      Set<String> vistas = new Set<String>();
      for (Perfil_Importacao__mdt p : perfisOrdenados()) {
        if (!podeUsar(p) || String.isBlank(p.BU__c) || vistas.contains(p.BU__c)) {
          continue;
        }
        vistas.add(p.BU__c);
        BuDTO b = new BuDTO();
        b.value = p.BU__c;
        b.label = rotulos.containsKey(p.BU__c) ? rotulos.get(p.BU__c) : p.BU__c;
        saida.add(b);
      }
      return saida;
    } catch (Exception e) {
      throw aura(e);
    }
  }

  @AuraEnabled(cacheable=true)
  public static List<PerfilDTO> getPerfis(String bu) {
    try {
      List<PerfilDTO> saida = new List<PerfilDTO>();
      Map<String, Schema.SObjectField> campos = Schema.SObjectType.Lead.fields.getMap();
      for (Perfil_Importacao__mdt p : perfisOrdenados()) {
        if (p.BU__c != bu || !podeUsar(p)) {
          continue;
        }
        PerfilDTO d = new PerfilDTO();
        d.developerName = p.DeveloperName;
        d.label = p.MasterLabel;
        d.descricao = p.Descricao__c;
        d.bu = p.BU__c;
        d.chave = p.Chave_Casamento__c;
        d.layout = p.Layout_Arquivo__c;
        d.modoDono = p.Modo_Dono__c;
        d.criarSemMatch = p.Criar_Sem_Match__c == true;
        d.colunaChave = p.Coluna_Chave__c;
        d.colunaCompany = p.Coluna_Company__c;
        d.colunaLastName = p.Coluna_LastName__c;
        d.maxLinhas = maxLinhas(p);
        for (Perfil_Importacao_Campo__mdt m : camposDoPerfil(p.DeveloperName)) {
          if (m.Ativo__c != true || String.isBlank(m.Campo_Lead__c)) {
            continue;
          }
          MapeamentoDTO md = new MapeamentoDTO();
          md.coluna = m.Coluna_Arquivo__c;
          md.campoLead = m.Campo_Lead__c;
          md.politica = m.Politica__c;
          md.usarNaCriacao = m.Usar_Na_Criacao__c == true;
          md.tipoConversao = m.Tipo_Conversao__c;
          md.ordem = m.Ordem__c;
          Schema.SObjectField f = campos.get(m.Campo_Lead__c.toLowerCase());
          md.label = f == null ? m.Campo_Lead__c : f.getDescribe().getLabel();
          d.mapeamentos.add(md);
        }
        saida.add(d);
      }
      return saida;
    } catch (Exception e) {
      throw aura(e);
    }
  }

  private static List<Perfil_Importacao__mdt> perfisOrdenados() {
    List<Perfil_Importacao__mdt> l = perfis().values();
    l.sort(new PorOrdem());
    return l;
  }

  private class PorOrdem implements Comparator<Perfil_Importacao__mdt> {
    public Integer compare(Perfil_Importacao__mdt a, Perfil_Importacao__mdt b) {
      Decimal oa = a.Ordem__c == null ? 999999 : a.Ordem__c;
      Decimal ob = b.Ordem__c == null ? 999999 : b.Ordem__c;
      if (oa == ob) {
        return 0;
      }
      return oa < ob ? -1 : 1;
    }
  }

  /** Rótulos das BUs a partir do global value set VS_Unidades (via BU__c do lote). */
  private static Map<String, String> rotulosBu() {
    Map<String, String> m = new Map<String, String>();
    for (
      Schema.PicklistEntry pe : Importacao_Lote__c.BU__c.getDescribe()
        .getPicklistValues()
    ) {
      m.put(pe.getValue(), pe.getLabel());
    }
    return m;
  }

  private static Integer maxLinhas(Perfil_Importacao__mdt p) {
    return p.Max_Linhas__c == null
      ? MAX_LINHAS_PADRAO
      : p.Max_Linhas__c.intValue();
  }

  // ==================================================================
  //  (a) Iniciar lote + carregar linhas em chunks
  // ==================================================================

  @AuraEnabled
  public static Id iniciarLote(
    String perfilDeveloperName,
    String nomeArquivo,
    Integer totalLinhas,
    String diagnostico
  ) {
    try {
      Perfil_Importacao__mdt p = perfilAutorizado(perfilDeveloperName);
      if (totalLinhas == null || totalLinhas <= 0) {
        throw new ImportacaoException('O arquivo não tem linhas de dados.');
      }
      Integer max = maxLinhas(p);
      if (totalLinhas > max) {
        throw new ImportacaoException(
          'O arquivo tem ' +
            totalLinhas +
            ' linhas; o máximo por upload é ' +
            max +
            '.'
        );
      }
      Importacao_Lote__c lote = new Importacao_Lote__c(
        Status__c = 'Em preview',
        BU__c = p.BU__c,
        Perfil_Importacao__c = p.DeveloperName,
        Nome_Arquivo__c = String.isBlank(nomeArquivo)
          ? null
          : nomeArquivo.abbreviate(255),
        Diagnostico_Arquivo__c = String.isBlank(diagnostico)
          ? null
          : diagnostico.abbreviate(32768),
        Qtd_Linhas__c = totalLinhas
      );
      insert lote;
      return lote.Id;
    } catch (Exception e) {
      throw aura(e);
    }
  }

  @AuraEnabled
  public static void adicionarLinhas(Id loteId, String linhasJson) {
    try {
      if (loteId == null || String.isBlank(linhasJson)) {
        return;
      }
      Perfil_Importacao__mdt p = perfilAutorizado(loteDe(loteId).Perfil_Importacao__c);
      // A LWC envia as linhas como string JSON e desserializamos aqui: um campo
      // Map<String,String> dentro de um tipo Apex NÃO é preenchido pela
      // marshalling nativa LWC->Apex (zera o objeto inteiro). JSON.deserialize
      // preenche corretamente.
      List<LinhaDTO> linhas = (List<LinhaDTO>) JSON.deserialize(
        linhasJson,
        List<LinhaDTO>.class
      );
      if (linhas == null || linhas.isEmpty()) {
        return;
      }
      List<Importacao_Linha__c> registros = new List<Importacao_Linha__c>();
      for (LinhaDTO d : linhas) {
        String original = d.chave == null ? '' : d.chave.trim();
        String normalizado = ImportacaoLeadsDocumento.normalizar(
          original,
          p.Chave_Casamento__c
        );
        registros.add(
          new Importacao_Linha__c(
            Lote__c = loteId,
            Numero_Linha__c = d.numeroLinha,
            Chave_Original__c = original.abbreviate(30),
            Chave_Normalizada__c = normalizado.length() > 14
              ? normalizado.substring(0, 14)
              : normalizado,
            Payload_JSON__c = JSON.serialize(
              d.valores == null ? new Map<String, String>() : d.valores
            )
          )
        );
      }
      insert registros;
    } catch (Exception e) {
      throw aura(e);
    }
  }

  private static Importacao_Lote__c loteDe(Id loteId) {
    List<Importacao_Lote__c> l = [
      SELECT Id, Name, Perfil_Importacao__c, Status__c
      FROM Importacao_Lote__c
      WHERE Id = :loteId
      LIMIT 1
    ];
    if (l.isEmpty()) {
      throw new ImportacaoException('Lote não encontrado ou sem acesso.');
    }
    return l[0];
  }

  // ==================================================================
  //  (b) Classificar o casamento pela chave do perfil
  // ==================================================================

  @AuraEnabled
  public static PreviewDTO classificar(Id loteId) {
    try {
      Importacao_Lote__c lote = loteDe(loteId);
      Perfil_Importacao__mdt p = perfilAutorizado(lote.Perfil_Importacao__c);
      String tipo = p.Chave_Casamento__c;
      Boolean criar = p.Criar_Sem_Match__c == true;

      PreviewDTO preview = new PreviewDTO();
      preview.loteId = loteId;
      preview.loteNome = lote.Name;
      preview.perfil = p.DeveloperName;
      preview.modoDono = p.Modo_Dono__c;
      preview.criarSemMatch = criar;
      preview.chave = tipo;

      // Pass 1: chaves válidas. Sem payload — leve.
      Set<String> chaves = new Set<String>();
      for (Importacao_Linha__c l : [
        SELECT Id, Chave_Original__c, Chave_Normalizada__c
        FROM Importacao_Linha__c
        WHERE Lote__c = :loteId
      ]) {
        if (ImportacaoLeadsDocumento.motivoInvalido(l.Chave_Original__c, tipo) == null) {
          chaves.add(l.Chave_Normalizada__c);
        }
      }

      Map<String, List<Lead>> ativosPorChave = new Map<String, List<Lead>>();
      Set<String> comConvertido = new Set<String>();
      Set<String> comContato = new Set<String>();
      if (!chaves.isEmpty()) {
        casar(p, chaves, ativosPorChave, comConvertido, comContato);
      }

      // Pass 2: classifica cada linha e grava em chunks.
      Set<String> semMatchVistos = new Set<String>();
      List<Importacao_Linha__c> buffer = new List<Importacao_Linha__c>();
      Integer multiplosDevolvidos = 0;
      Map<String, Integer> amostraPorBalde = new Map<String, Integer>();

      for (Importacao_Linha__c l : [
        SELECT
          Id,
          Numero_Linha__c,
          Chave_Original__c,
          Chave_Normalizada__c,
          Payload_JSON__c
        FROM Importacao_Linha__c
        WHERE Lote__c = :loteId
        ORDER BY Numero_Linha__c ASC NULLS LAST, Name ASC
      ]) {
        preview.total++;
        String norm = l.Chave_Normalizada__c;
        String motivo = ImportacaoLeadsDocumento.motivoInvalido(
          l.Chave_Original__c,
          tipo
        );
        String balde;
        String acao;
        String resumo = '';
        List<LeadAlvoDTO> alvos = new List<LeadAlvoDTO>();

        if (motivo != null) {
          balde = 'INVALIDO';
          acao = 'IGNORAR';
          resumo = mensagemMotivo(motivo, tipo);
          preview.invalido++;
        } else if (comContato.contains(norm)) {
          balde = 'JA_CONTATO';
          acao = 'IGNORAR';
          resumo = MSG_JA_CONTATO;
          preview.jaContato++;
        } else if (
          ativosPorChave.containsKey(norm) && !ativosPorChave.get(norm).isEmpty()
        ) {
          List<Lead> casados = ativosPorChave.get(norm);
          for (Lead c : casados) {
            LeadAlvoDTO a = new LeadAlvoDTO();
            a.id = c.Id;
            a.nome = c.Name;
            a.empresa = c.Company;
            a.owner = c.Owner == null ? null : c.Owner.Name;
            a.selecionado = true;
            alvos.add(a);
          }
          acao = 'ATUALIZAR';
          if (casados.size() == 1) {
            balde = 'MATCH_UNICO';
            preview.matchUnico++;
          } else {
            balde = 'MATCH_MULTIPLO';
            resumo = casados.size() + ' leads casam esta chave.';
            preview.matchMultiplo++;
          }
        } else if (comConvertido.contains(norm)) {
          balde = 'CONVERTIDO';
          acao = 'IGNORAR';
          resumo = 'Só casou com lead convertido.';
          preview.convertido++;
        } else if (!criar) {
          balde = 'SEM_MATCH';
          acao = 'IGNORAR';
          resumo = MSG_STE_SEM_MATCH;
          preview.semMatch++;
        } else if (semMatchVistos.contains(norm)) {
          balde = 'DUPLICADO_NO_ARQUIVO';
          acao = 'IGNORAR';
          resumo = 'Chave repetida no arquivo sem match — não recria.';
          preview.duplicado++;
        } else if (temCompanyELastName(payloadDe(l.Payload_JSON__c))) {
          balde = 'SEM_MATCH';
          acao = 'CRIAR';
          semMatchVistos.add(norm);
          preview.semMatch++;
        } else {
          // Não entra em semMatchVistos: outra linha da mesma chave com
          // Company/LastName ainda pode criar.
          balde = 'INVALIDO';
          acao = 'IGNORAR';
          resumo = 'Sem Company e LastName mapeáveis — não dá para criar.';
          preview.invalido++;
        }

        l.Resultado_Match__c = balde;
        l.Motivo_Invalido__c = motivo;
        l.Acao__c = acao;
        l.Leads_Alvo__c = alvos.isEmpty() ? null : JSON.serialize(alvos);
        l.Resultado_Processamento__c = null;
        l.Erro__c = resumo == '' ? null : resumo;
        buffer.add(l);

        LinhaPreviewDTO pv = new LinhaPreviewDTO();
        pv.linhaId = l.Id;
        pv.numeroLinha = l.Numero_Linha__c == null
          ? null
          : l.Numero_Linha__c.intValue();
        pv.chaveOriginal = l.Chave_Original__c;
        pv.chaveNormalizada = norm;
        pv.resultadoMatch = balde;
        pv.motivoInvalido = motivo;
        pv.acao = acao;
        pv.resumo = resumo;
        pv.leadsAlvo = alvos;
        if (
          balde == 'MATCH_MULTIPLO' && multiplosDevolvidos < MAX_MULTIPLO_RETORNO
        ) {
          preview.multiplos.add(pv);
          multiplosDevolvidos++;
        } else {
          Integer vistos = amostraPorBalde.containsKey(balde)
            ? amostraPorBalde.get(balde)
            : 0;
          if (vistos < AMOSTRA_POR_BALDE) {
            preview.amostra.add(pv);
            amostraPorBalde.put(balde, vistos + 1);
          }
        }

        if (buffer.size() >= CHUNK_UPDATE) {
          update buffer;
          buffer.clear();
        }
      }
      if (!buffer.isEmpty()) {
        update buffer;
      }

      lote.Qtd_Linhas__c = preview.total;
      lote.Qtd_Multiplos__c = preview.matchMultiplo;
      lote.Qtd_Sem_Match__c = preview.semMatch;
      lote.Qtd_Convertidos__c = preview.convertido;
      lote.Qtd_Invalidos__c = preview.invalido;
      update lote;

      return preview;
    } catch (Exception e) {
      throw aura(e);
    }
  }

  /**
   * Casamento só entre leads do Record Type do perfil. CNPJ: CNPJ_Normalizado__c.
   * CPF: Lead.CPF__c nos dois formatos e, à parte, Contact.CPF__c (JA_CONTATO).
   * Leitura em contexto de sistema com o compartilhamento do operador (classe
   * `with sharing`); a FLS de Lead é imposta na gravação.
   */
  private static void casar(
    Perfil_Importacao__mdt p,
    Set<String> chaves,
    Map<String, List<Lead>> ativosPorChave,
    Set<String> comConvertido,
    Set<String> comContato
  ) {
    String rtDev = p.Record_Type__c;
    List<Lead> casados;
    if (p.Chave_Casamento__c == ImportacaoLeadsDocumento.CHAVE_CPF) {
      Set<String> formatos = new Set<String>();
      for (String c : chaves) {
        formatos.addAll(ImportacaoLeadsDocumento.formatosCpf(c));
      }
      for (Contact ct : [SELECT CPF__c FROM Contact WHERE CPF__c IN :formatos]) {
        comContato.add(ImportacaoLeadsDocumento.normalizarCpf(ct.CPF__c));
      }
      casados = [
        SELECT Id, Name, Company, IsConverted, Owner.Name, CPF__c
        FROM Lead
        WHERE CPF__c IN :formatos AND RecordType.DeveloperName = :rtDev
      ];
    } else {
      casados = [
        SELECT Id, Name, Company, IsConverted, Owner.Name, CNPJ_Normalizado__c
        FROM Lead
        WHERE
          CNPJ_Normalizado__c IN :chaves
          AND RecordType.DeveloperName = :rtDev
      ];
    }
    for (Lead ld : casados) {
      String chave = p.Chave_Casamento__c == ImportacaoLeadsDocumento.CHAVE_CPF
        ? ImportacaoLeadsDocumento.normalizarCpf(ld.CPF__c)
        : ld.CNPJ_Normalizado__c;
      if (ld.IsConverted) {
        comConvertido.add(chave);
        continue;
      }
      if (!ativosPorChave.containsKey(chave)) {
        ativosPorChave.put(chave, new List<Lead>());
      }
      ativosPorChave.get(chave).add(ld);
    }
  }

  private static String mensagemMotivo(String motivo, String tipo) {
    String doc = tipo == ImportacaoLeadsDocumento.CHAVE_CPF ? 'CPF' : 'CNPJ';
    if (motivo == ImportacaoLeadsDocumento.MOTIVO_NOTACAO) {
      return doc + ' em notação científica (o Excel apagou dígitos).';
    }
    if (motivo == ImportacaoLeadsDocumento.MOTIVO_DV) {
      return doc + ' com dígito verificador inválido.';
    }
    if (motivo == ImportacaoLeadsDocumento.MOTIVO_AUSENTE) {
      return doc + ' ausente.';
    }
    return doc + ' com tamanho ou formato inválido.';
  }

  /** Payload JSON da linha como Map<campo, texto>. JSON corrompido vira mapa vazio. */
  public static Map<String, String> payloadDe(String texto) {
    if (String.isBlank(texto)) {
      return new Map<String, String>();
    }
    try {
      Map<String, Object> cru = (Map<String, Object>) JSON.deserializeUntyped(texto);
      Map<String, String> saida = new Map<String, String>();
      for (String k : cru.keySet()) {
        saida.put(k, cru.get(k) == null ? null : String.valueOf(cru.get(k)));
      }
      return saida;
    } catch (Exception e) {
      return new Map<String, String>();
    }
  }

  private static Boolean temCompanyELastName(Map<String, String> valores) {
    return valores != null &&
      String.isNotBlank(valores.get('Company')) &&
      String.isNotBlank(valores.get('LastName'));
  }

  // ==================================================================
  //  (c) Confirmar e enfileirar o batch
  // ==================================================================

  @AuraEnabled
  public static Id confirmar(Id loteId, List<SelecaoDTO> selecoes) {
    try {
      if (loteId == null) {
        throw new ImportacaoException('Lote não informado.');
      }
      Importacao_Lote__c lote = loteDe(loteId);
      perfilAutorizado(lote.Perfil_Importacao__c);

      // Aplica as escolhas do operador. Só linhas casadas aceitam override, e
      // só para ATUALIZAR ou IGNORAR: o cliente nunca promove uma linha a CRIAR.
      if (selecoes != null && !selecoes.isEmpty()) {
        Map<Id, SelecaoDTO> porLinha = new Map<Id, SelecaoDTO>();
        for (SelecaoDTO s : selecoes) {
          if (s != null && s.linhaId != null) {
            porLinha.put(s.linhaId, s);
          }
        }
        List<Importacao_Linha__c> paraAtualizar = new List<Importacao_Linha__c>();
        for (Importacao_Linha__c l : [
          SELECT Id, Resultado_Match__c, Acao__c, Leads_Alvo__c
          FROM Importacao_Linha__c
          WHERE
            Id IN :porLinha.keySet()
            AND Lote__c = :loteId
            AND Resultado_Match__c IN ('MATCH_UNICO', 'MATCH_MULTIPLO')
        ]) {
          SelecaoDTO s = porLinha.get(l.Id);
          if (s.acao == 'ATUALIZAR' || s.acao == 'IGNORAR') {
            l.Acao__c = s.acao;
          }
          if (s.leadsSelecionados != null && String.isNotBlank(l.Leads_Alvo__c)) {
            Set<Id> escolhidos = new Set<Id>(s.leadsSelecionados);
            List<LeadAlvoDTO> alvos = (List<LeadAlvoDTO>) JSON.deserialize(
              l.Leads_Alvo__c,
              List<LeadAlvoDTO>.class
            );
            Boolean algum = false;
            for (LeadAlvoDTO a : alvos) {
              a.selecionado = escolhidos.contains(a.id);
              algum = algum || a.selecionado;
            }
            l.Leads_Alvo__c = JSON.serialize(alvos);
            // Múltiplo sem nenhum selecionado vira IGNORAR.
            if (!algum && l.Acao__c == 'ATUALIZAR') {
              l.Acao__c = 'IGNORAR';
            }
          }
          paraAtualizar.add(l);
        }
        if (!paraAtualizar.isEmpty()) {
          update paraAtualizar;
        }
      }

      lote.Status__c = 'Processando';
      update lote;

      Id jobId = Database.executeBatch(new ImportacaoLeadsBatch(loteId), 50);

      lote.AsyncApexJobId__c = String.valueOf(jobId);
      update lote;
      return jobId;
    } catch (Exception e) {
      throw aura(e);
    }
  }

  // ==================================================================
  //  (d) Consultar status (polling)
  // ==================================================================

  @AuraEnabled
  public static StatusDTO consultarStatus(Id loteId) {
    try {
      Importacao_Lote__c lote = [
        SELECT
          Id,
          Name,
          Status__c,
          AsyncApexJobId__c,
          Qtd_Linhas__c,
          Qtd_Atualizados__c,
          Qtd_Criados__c,
          Qtd_Multiplos__c,
          Qtd_Sem_Match__c,
          Qtd_Convertidos__c,
          Qtd_Invalidos__c,
          Qtd_Ignorados__c,
          Qtd_Erros__c,
          Mensagens__c
        FROM Importacao_Lote__c
        WHERE Id = :loteId
        LIMIT 1
      ];

      StatusDTO dto = new StatusDTO();
      dto.loteId = lote.Id;
      dto.loteNome = lote.Name;
      dto.status = lote.Status__c;
      dto.qtdLinhas = inteiro(lote.Qtd_Linhas__c);
      dto.qtdAtualizados = inteiro(lote.Qtd_Atualizados__c);
      dto.qtdCriados = inteiro(lote.Qtd_Criados__c);
      dto.qtdMultiplos = inteiro(lote.Qtd_Multiplos__c);
      dto.qtdSemMatch = inteiro(lote.Qtd_Sem_Match__c);
      dto.qtdConvertidos = inteiro(lote.Qtd_Convertidos__c);
      dto.qtdInvalidos = inteiro(lote.Qtd_Invalidos__c);
      dto.qtdIgnorados = inteiro(lote.Qtd_Ignorados__c);
      dto.qtdErros = inteiro(lote.Qtd_Erros__c);
      dto.mensagens = lote.Mensagens__c;

      if (String.isNotBlank(lote.AsyncApexJobId__c)) {
        List<AsyncApexJob> jobs = [
          SELECT Status, JobItemsProcessed, TotalJobItems
          FROM AsyncApexJob
          WHERE Id = :lote.AsyncApexJobId__c
          LIMIT 1
        ];
        if (!jobs.isEmpty()) {
          dto.jobStatus = jobs[0].Status;
          dto.jobItensProcessados = jobs[0].JobItemsProcessed;
          dto.jobItensTotal = jobs[0].TotalJobItems;
        }
      }
      return dto;
    } catch (Exception e) {
      throw aura(e);
    }
  }

  private static Integer inteiro(Decimal d) {
    return d == null ? 0 : d.intValue();
  }

  /** Converte qualquer exceção em mensagem controlada para o LWC. */
  private static AuraHandledException aura(Exception e) {
    System.debug(
      LoggingLevel.ERROR,
      'ImportacaoLeadsController: ' +
        e.getTypeName() +
        ': ' +
        e.getMessage() +
        '\n' +
        e.getStackTraceString()
    );
    String msg = e instanceof ImportacaoException
      ? e.getMessage()
      : 'Não foi possível concluir a operação. Verifique o log do sistema para detalhes.';
    AuraHandledException ex = new AuraHandledException(msg);
    ex.setMessage(msg);
    return ex;
  }
}
