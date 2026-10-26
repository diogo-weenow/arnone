/**
 * Importação de leads — fundação dos testes. Substitui o
 * SOLEnriquecimentoTestFactory.
 *
 * Centraliza: documentos de DV válido, perfis e matrizes injetados (CMDT não
 * aceita DML), o singleton e a fila sintética da distribuição SOL (mesmo padrão
 * do SOLDistribuicaoServiceTest), usuários por persona com os permission sets
 * da importação e a montagem de lotes e linhas.
 */
@IsTest
public class ImportacaoLeadsTestFactory {
  public static final String FILA_DEV = 'Fila_Importacao_Teste';

  public static final String PS_BASE = 'PS_Importacao_Leads';
  public static final String PS_SOL = 'PS_SOL_Importacao_Leads';
  public static final String PS_STE = 'PS_STE_Importacao_Leads';
  public static final String PS_ESG = 'PS_ESG_Importacao_Leads';
  public static final String PS_SCO = 'PS_SCO_Importacao_Leads';

  // CNPJs e CPFs com DV válido (algoritmo da Receita).
  public static final String CNPJ_A = '11222333000181';
  public static final String CNPJ_B = '11444777000161';
  public static final String CNPJ_ZERO = '01234567000195'; // 13 dígitos sem o zero
  public static final String CNPJ_ALFA = '12ABC34501DE35'; // exemplo oficial
  public static final String CPF_A = '12345678909';
  public static final String CPF_ZERO = '01234567890'; // 10 dígitos sem o zero
  public static final String CPF_B = '98765432100';
  public static final String CPF_C = '11144477735';

  /** CNPJ numérico de DV válido a partir de um número base (até 12 dígitos). */
  public static String cnpjValido(Long base) {
    String b = String.valueOf(base).leftPad(12, '0');
    return b + ImportacaoLeadsDocumento.dvCnpj(b);
  }

  public static Id rt(String developerName) {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get(developerName)
      .getRecordTypeId();
  }

  public static String statusPadrao() {
    List<LeadStatus> p = [
      SELECT MasterLabel
      FROM LeadStatus
      WHERE IsDefault = TRUE
      LIMIT 1
    ];
    return p.isEmpty() ? 'Novo' : p[0].MasterLabel;
  }

  // ---------------------------------------------------------------- perfis

  /** Perfil em memória (JSON: DeveloperName/MasterLabel não são graváveis). */
  public static Perfil_Importacao__mdt perfil(
    String dev,
    String bu,
    String chave,
    String modo,
    Boolean criar,
    Boolean ativo
  ) {
    Map<String, Object> m = new Map<String, Object>{
      'DeveloperName' => dev,
      'MasterLabel' => dev,
      'BU__c' => bu,
      'Record_Type__c' => bu,
      'Unidade_Origem__c' => bu,
      'Chave_Casamento__c' => chave,
      'Layout_Arquivo__c' => 'GENERICO',
      'Modo_Dono__c' => modo,
      'Permissao_Customizada__c' => bu + '_Importar_Leads',
      'Criar_Sem_Match__c' => criar,
      'Coluna_Chave__c' => chave,
      'Max_Linhas__c' => 5000,
      'Ordem__c' => 10,
      'Ativo__c' => ativo
    };
    return (Perfil_Importacao__mdt) JSON.deserialize(
      JSON.serialize(m),
      Perfil_Importacao__mdt.class
    );
  }

  public static Perfil_Importacao_Campo__mdt campo(
    String campoLead,
    String politica,
    String tipo,
    Boolean criacao
  ) {
    return new Perfil_Importacao_Campo__mdt(
      Campo_Lead__c = campoLead,
      Coluna_Arquivo__c = campoLead,
      Politica__c = politica,
      Tipo_Conversao__c = tipo,
      Usar_Na_Criacao__c = criacao,
      Ativo__c = true
    );
  }

  /**
   * Matriz SOL determinística: NumberOfEmployees (OVERWRITE), Phone e Website
   * (FILL_BLANK). Injetada sobre o CMDT real; a fila sintética substitui a
   * Fila_Leads_SOL na distribuição.
   */
  public static void aplicarOverridesSol() {
    ImportacaoLeadsController.camposOverride = new Map<String, List<Perfil_Importacao_Campo__mdt>>{
      'SOL_Generico' => new List<Perfil_Importacao_Campo__mdt>{
        campo('NumberOfEmployees', 'OVERWRITE', 'NUMBER', true),
        campo('Phone', 'FILL_BLANK', 'TEXT', true),
        campo('Website', 'FILL_BLANK', 'TEXT', false)
      }
    };
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_DEV;
  }

  /** Injeta o perfil ESG ATIVO (o CMDT real é inativo) com a matriz do handoff. */
  public static void injetarEsgAtivo() {
    ImportacaoLeadsController.perfisOverride = new Map<String, Perfil_Importacao__mdt>{
      'ESG_Generico' => perfil(
        'ESG_Generico',
        'ESG',
        'CNPJ',
        ImportacaoLeadsController.MODO_REGRA_ATRIBUICAO,
        true,
        true
      )
    };
    ImportacaoLeadsController.camposOverride = new Map<String, List<Perfil_Importacao_Campo__mdt>>{
      'ESG_Generico' => new List<Perfil_Importacao_Campo__mdt>{
        campo('Email', 'FILL_BLANK', 'TEXT', true),
        campo('Phone', 'FILL_BLANK', 'TEXT', true)
      }
    };
  }

  public static void semearSingleton() {
    if ([SELECT COUNT() FROM SOL_Distribuicao_Estado__c] == 0) {
      insert new SOL_Distribuicao_Estado__c(Name = 'SOL', Ativo__c = true);
    }
  }

  // ---------------------------------------------------------------- personas

  /** Atribui os permission sets ao usuário (idempotente, em runAs isolado). */
  public static void atribuirPs(Id userId, List<String> nomes) {
    Set<Id> ja = new Set<Id>();
    for (PermissionSetAssignment a : [
      SELECT PermissionSetId
      FROM PermissionSetAssignment
      WHERE AssigneeId = :userId
    ]) {
      ja.add(a.PermissionSetId);
    }
    List<PermissionSetAssignment> novas = new List<PermissionSetAssignment>();
    for (PermissionSet ps : [
      SELECT Id
      FROM PermissionSet
      WHERE Name IN :nomes
    ]) {
      if (!ja.contains(ps.Id)) {
        novas.add(
          new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = ps.Id)
        );
      }
    }
    if (!novas.isEmpty()) {
      System.runAs(new User(Id = UserInfo.getUserId())) {
        insert novas;
      }
    }
  }

  /** Usuário com o perfil "Minimum Access - Salesforce" e os PS informados. */
  public static User persona(String apelido, List<String> nomesPs) {
    Profile p = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Minimum Access - Salesforce'
      LIMIT 1
    ];
    return usuario(apelido, p.Id, nomesPs);
  }

  /**
   * Operador com o perfil de quem roda o teste (enxerga os leads) e os PS
   * informados. Necessário porque a custom permission de uma PSA criada no
   * setup só é vista pelo FeatureManagement dentro de System.runAs.
   */
  public static User operador(List<String> nomesPs) {
    return usuario('operador', UserInfo.getProfileId(), nomesPs);
  }

  /** Operador criado no @TestSetup por operador(). */
  public static User operadorDoSetup() {
    return [
      SELECT Id
      FROM User
      WHERE Username LIKE 'imp.operador.%@arnone.importacao.test.invalid'
      LIMIT 1
    ];
  }

  private static User usuario(String apelido, Id profileId, List<String> nomesPs) {
    Profile p = new Profile(Id = profileId);
    User u = new User(
      FirstName = 'Imp',
      LastName = 'Persona ' + apelido,
      Alias = ('ip' + apelido).left(8),
      Email = 'imp.' + apelido + '@arnone.invalid',
      Username = 'imp.' +
        apelido +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.importacao.test.invalid',
      ProfileId = p.Id,
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR'
    );
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert u;
    }
    atribuirPs(u.Id, nomesPs);
    return u;
  }

  private static User montarVendedor(String apelido) {
    String unico = String.valueOf(Math.abs(Crypto.getRandomInteger())) + apelido;
    return new User(
      FirstName = 'Imp',
      LastName = 'Vend ' + apelido,
      Alias = ('iv' + apelido).left(8),
      Email = 'iv.' + apelido + '@arnone.invalid',
      Username = 'iv.imp.' + unico + '@arnone.importacao.test.invalid',
      ProfileId = UserInfo.getProfileId(),
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  /** Cria a fila sintética da distribuição SOL com N vendedores. Devolve ids. */
  public static List<Id> montarFila(Integer qtdVendedores) {
    List<User> criados = new List<User>();
    for (Integer i = 0; i < qtdVendedores; i++) {
      criados.add(montarVendedor('v' + i));
    }
    List<Id> ids = new List<Id>();
    System.runAs(new User(Id = UserInfo.getUserId())) {
      if (!criados.isEmpty()) {
        insert criados;
      }
      Group fila = new Group(
        Name = 'Fila Importacao Teste',
        DeveloperName = FILA_DEV,
        Type = 'Queue'
      );
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
      List<GroupMember> gms = new List<GroupMember>();
      for (User u : criados) {
        gms.add(new GroupMember(GroupId = fila.Id, UserOrGroupId = u.Id));
      }
      insert gms;
    }
    for (User u : criados) {
      ids.add(u.Id);
    }
    ids.sort();
    return ids;
  }

  // ---------------------------------------------------------------- leads

  /** Lead com Record Type da BU e CNPJ formatado (dispara o normalizador). */
  public static Lead novoLeadCnpj(
    String rtDev,
    String last,
    String company,
    String cnpj14
  ) {
    Lead l = new Lead(
      RecordTypeId = rt(rtDev),
      LastName = last,
      Company = company,
      CNPJ__c = ImportacaoLeadsDocumento.formatarCnpj(cnpj14),
      Status = statusPadrao()
    );
    insert l;
    return l;
  }

  public static Lead novoLeadSOL(String last, String company, String cnpj14) {
    return novoLeadCnpj('SOL', last, company, cnpj14);
  }

  /** Lead STE com o CPF gravado exatamente como informado (mascarado ou não). */
  public static Lead novoLeadCpf(String rtDev, String last, String cpfGravado) {
    Lead l = new Lead(
      RecordTypeId = rt(rtDev),
      LastName = last,
      Company = last,
      CPF__c = cpfGravado,
      Status = statusPadrao()
    );
    insert l;
    return l;
  }

  // ---------------------------------------------------------------- lotes

  public static Importacao_Lote__c novoLote(String perfilDev) {
    Importacao_Lote__c lote = new Importacao_Lote__c(
      Status__c = 'Em preview',
      Perfil_Importacao__c = perfilDev
    );
    insert lote;
    return lote;
  }

  public static String alvosJson(List<Id> ids, List<Boolean> selecionados) {
    List<Map<String, Object>> l = new List<Map<String, Object>>();
    for (Integer i = 0; i < ids.size(); i++) {
      l.add(new Map<String, Object>{ 'id' => ids[i], 'selecionado' => selecionados[i] });
    }
    return JSON.serialize(l);
  }

  public static Importacao_Linha__c linhaAtualizar(
    Id loteId,
    Integer num,
    String chave,
    Map<String, String> valores,
    List<Id> alvosSelecionados
  ) {
    List<Boolean> sel = new List<Boolean>();
    for (Integer i = 0; i < alvosSelecionados.size(); i++) {
      sel.add(true);
    }
    return new Importacao_Linha__c(
      Lote__c = loteId,
      Numero_Linha__c = num,
      Chave_Original__c = chave,
      Chave_Normalizada__c = chave,
      Payload_JSON__c = JSON.serialize(valores),
      Resultado_Match__c = alvosSelecionados.size() > 1
        ? 'MATCH_MULTIPLO'
        : 'MATCH_UNICO',
      Acao__c = 'ATUALIZAR',
      Leads_Alvo__c = alvosJson(alvosSelecionados, sel)
    );
  }

  public static Importacao_Linha__c linhaCriar(
    Id loteId,
    Integer num,
    String cnpj14,
    Map<String, String> valores
  ) {
    return new Importacao_Linha__c(
      Lote__c = loteId,
      Numero_Linha__c = num,
      Chave_Original__c = cnpj14,
      Chave_Normalizada__c = cnpj14,
      Payload_JSON__c = JSON.serialize(valores),
      Resultado_Match__c = 'SEM_MATCH',
      Acao__c = 'CRIAR'
    );
  }

  /** Payload de criação: Company/LastName + NumberOfEmployees. */
  public static Map<String, String> payloadCriar(String funcionarios) {
    return new Map<String, String>{
      'NumberOfEmployees' => funcionarios,
      'Company' => 'Nova Empresa Importação',
      'LastName' => 'Novo Contato'
    };
  }
}
