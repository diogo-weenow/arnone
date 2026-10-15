/**
 * Upload enriquecimento Lemit — fundação dos testes.
 *
 * Centraliza: a matriz CMDT determinística em memória (CMDT não aceita DML), o
 * singleton e a fila sintética da distribuição (mesmo padrão provado do
 * SOLDistribuicaoServiceTest, com os overrides @TestVisible) e a montagem de
 * Lotes/Linhas de enriquecimento.
 */
@IsTest
public class SOLEnriquecimentoTestFactory {
  public static final String FILA_DEV = 'Fila_Enriq_Lemit_Teste';

  public static Id rtSol() {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
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

  /** Matriz determinística: OVERWRITE (NumberOfEmployees) e FILL_BLANK (Phone). */
  public static Map<String, SOL_Lemit_Mapeamento__mdt> matriz() {
    Map<String, SOL_Lemit_Mapeamento__mdt> m = new Map<String, SOL_Lemit_Mapeamento__mdt>();
    m.put(
      'NumberOfEmployees',
      new SOL_Lemit_Mapeamento__mdt(
        Campo_Lead__c = 'NumberOfEmployees',
        Politica__c = 'OVERWRITE',
        Tipo_Conversao__c = 'NUMBER',
        Usar_Na_Criacao__c = true,
        Ativo__c = true
      )
    );
    m.put(
      'Phone',
      new SOL_Lemit_Mapeamento__mdt(
        Campo_Lead__c = 'Phone',
        Politica__c = 'FILL_BLANK',
        Tipo_Conversao__c = 'TEXT',
        Usar_Na_Criacao__c = true,
        Ativo__c = true
      )
    );
    return m;
  }

  public static void aplicarOverrides() {
    SOLEnriquecimentoController.matrizOverride = matriz();
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_DEV;
  }

  public static void semearSingleton() {
    if ([SELECT COUNT() FROM SOL_Distribuicao_Estado__c] == 0) {
      insert new SOL_Distribuicao_Estado__c(Name = 'SOL', Ativo__c = true);
    }
  }

  /**
   * Dá ao usuário que roda o teste o PS_SOL_Enriquecimento. Chamado no
   * @TestSetup (transação própria), garante que os métodos de teste rodem com a
   * FLS dos campos novos (SOL_CNPJ_Normalizado__c, campos-alvo), como o operador
   * real teria. Isolado em System.runAs para não misturar DML de setup com o
   * resto. Idempotente.
   */
  public static void atribuirPsAoUsuarioAtual() {
    Id uid = UserInfo.getUserId();
    List<PermissionSet> ps = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = 'PS_SOL_Enriquecimento'
      LIMIT 1
    ];
    if (ps.isEmpty()) {
      return;
    }
    Integer ja = [
      SELECT COUNT()
      FROM PermissionSetAssignment
      WHERE AssigneeId = :uid AND PermissionSetId = :ps[0].Id
    ];
    if (ja > 0) {
      return;
    }
    System.runAs(new User(Id = uid)) {
      insert new PermissionSetAssignment(
        AssigneeId = uid,
        PermissionSetId = ps[0].Id
      );
    }
  }

  private static User montarUsuario(String apelido) {
    String unico =
      String.valueOf(Math.abs(Crypto.getRandomInteger())) + apelido;
    return new User(
      FirstName = 'Enriq',
      LastName = 'Vend ' + apelido,
      Alias = ('en' + apelido).left(8),
      Email = 'en.' + apelido + '@arnone.invalid',
      Username = 'en.lemit.' + unico + '@arnone.lemit.test.invalid',
      ProfileId = UserInfo.getProfileId(),
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  /** Cria a fila sintética com N vendedores diretos ativos. Devolve ids. */
  public static List<Id> montarFila(Integer qtdVendedores) {
    List<User> criados = new List<User>();
    for (Integer i = 0; i < qtdVendedores; i++) {
      criados.add(montarUsuario('v' + i));
    }
    List<Id> ids = new List<Id>();
    System.runAs(new User(Id = UserInfo.getUserId())) {
      if (!criados.isEmpty()) {
        insert criados;
      }
      Group fila = new Group(
        Name = 'Fila Enriq Lemit Teste',
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

  /** Insere um Lead SOL (dispara before-save normalizador + distribuição). */
  public static Lead novoLeadSOL(String last, String company, String cnpj14) {
    Lead l = new Lead(
      RecordTypeId = rtSol(),
      LastName = last,
      Company = company,
      CNPJ__c = SOLEnriquecimentoUtil.formatarCnpj(cnpj14),
      Status = statusPadrao()
    );
    insert l;
    return l;
  }

  public static SOL_Enriquecimento_Lote__c novoLote() {
    SOL_Enriquecimento_Lote__c lote = new SOL_Enriquecimento_Lote__c(
      Status__c = 'Em preview'
    );
    insert lote;
    return lote;
  }

  public static String alvosJson(List<Id> ids, List<Boolean> selecionados) {
    List<Map<String, Object>> l = new List<Map<String, Object>>();
    for (Integer i = 0; i < ids.size(); i++) {
      l.add(
        new Map<String, Object>{
          'id' => ids[i],
          'selecionado' => selecionados[i]
        }
      );
    }
    return JSON.serialize(l);
  }

  public static SOL_Enriquecimento_Linha__c linhaAtualizar(
    Id loteId,
    Integer num,
    String cnpj14,
    Map<String, String> valores,
    List<Id> alvosSelecionados
  ) {
    List<Boolean> sel = new List<Boolean>();
    for (Integer i = 0; i < alvosSelecionados.size(); i++) {
      sel.add(true);
    }
    return new SOL_Enriquecimento_Linha__c(
      Lote__c = loteId,
      Numero_Linha__c = num,
      CNPJ_Original__c = cnpj14,
      CNPJ_Normalizado__c = cnpj14,
      Payload_JSON__c = JSON.serialize(valores),
      Resultado_Match__c = alvosSelecionados.size() > 1
        ? 'MATCH_MULTIPLO'
        : 'MATCH_UNICO',
      Acao__c = 'ATUALIZAR',
      Leads_Alvo__c = alvosJson(alvosSelecionados, sel)
    );
  }

  public static SOL_Enriquecimento_Linha__c linhaCriar(
    Id loteId,
    Integer num,
    String cnpj14,
    Map<String, String> valores
  ) {
    return new SOL_Enriquecimento_Linha__c(
      Lote__c = loteId,
      Numero_Linha__c = num,
      CNPJ_Original__c = cnpj14,
      CNPJ_Normalizado__c = cnpj14,
      Payload_JSON__c = JSON.serialize(valores),
      Resultado_Match__c = 'SEM_MATCH',
      Acao__c = 'CRIAR'
    );
  }
}
