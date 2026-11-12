/**
 * Testes de comportamento dos flows disparados por registro que não tinham
 * nenhuma classe de teste (ADV e STech Telecom).
 *
 * Motivo: produção tem "Implantar processos e flows como ativos" ligado, e o
 * deploy de flow ativo exige que pelo menos 75% dos flows ativos da org sejam
 * exercitados por teste. Cada método verifica o efeito real do flow, não só a
 * passagem por ele.
 *
 * Os registros nascem direto na etapa-alvo, de propósito: as VRs de transição
 * do STech (STE_PreMatricula_Completa, STE_Cadencia_Completa) só olham
 * mudança de etapa, e o que está em teste aqui é o flow, não a VR.
 */
@IsTest
private class FlowsSemTesteCoberturaTest {
  private static Id rt(String developerName) {
    return Opportunity.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get(developerName)
      .getRecordTypeId();
  }

  private static Id conta() {
    Account a = new Account(Name = 'Conta flows ' + Crypto.getRandomInteger());
    insert a;
    return a.Id;
  }

  private static Opportunity novaAdv(Id contaId, String etapa) {
    return new Opportunity(
      Name = 'Opp ADV flows',
      AccountId = contaId,
      RecordTypeId = rt('ADV'),
      CloseDate = Date.today().addDays(30),
      StageName = etapa,
      ADV_Area_Juridica__c = 'Trabalhista',
      ADV_Advogado_Responsavel__c = 'Caroline Dagostino'
    );
  }

  private static Opportunity novaSteTelecom(Id contaId, String etapa) {
    return new Opportunity(
      Name = 'Opp STE flows',
      AccountId = contaId,
      RecordTypeId = rt('STE_Telecom'),
      CloseDate = Date.today().addDays(30),
      StageName = etapa
    );
  }

  // ---------------------------------------------------------------- ADV

  @IsTest
  static void advPropostaEnviadaCarimbaDataDeEnvio() {
    Opportunity o = novaAdv(conta(), 'Proposta Enviada');
    insert o;

    o = [SELECT ADV_Data_Envio_Proposta__c FROM Opportunity WHERE Id = :o.Id];
    Assert.areEqual(
      Date.today(),
      o.ADV_Data_Envio_Proposta__c,
      'ADV_Carimbo_Envio_Proposta grava a data de envio ao entrar em Proposta Enviada.'
    );
  }

  @IsTest
  static void advGanhoSemContratoAnexadoEhRecusado() {
    Opportunity o = novaAdv(conta(), 'Aguardando Assinatura');
    insert o;

    o.StageName = 'Ganho';
    o.ADV_Data_Assinatura__c = Date.today();
    Database.SaveResult sr = Database.update(o, false);

    Assert.isFalse(
      sr.isSuccess(),
      'ADV_Validar_Ganho_Com_Contrato barra o Ganho sem contrato anexado.'
    );
    Assert.isTrue(
      sr.getErrors()[0].getMessage().contains('contrato assinado'),
      'A mensagem pede o contrato: ' + sr.getErrors()[0].getMessage()
    );
  }

  @IsTest
  static void advGanhoComContratoAnexadoEhAceito() {
    Opportunity o = novaAdv(conta(), 'Aguardando Assinatura');
    insert o;
    insert new ContentVersion(
      Title = 'Contrato assinado',
      PathOnClient = 'contrato.pdf',
      VersionData = Blob.valueOf('contrato'),
      FirstPublishLocationId = o.Id
    );

    o.StageName = 'Ganho';
    o.ADV_Data_Assinatura__c = Date.today();
    update o;

    Assert.areEqual(
      'Ganho',
      [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
      'Com o contrato em Arquivos, o Ganho é aceito.'
    );
  }

  @IsTest
  static void advEmPrecificacaoAvisaSemCriarTarefaDeFalha() {
    Opportunity o = novaAdv(conta(), 'Oportunidade Recebida');
    insert o;

    Test.startTest();
    o.StageName = 'Em Precificação';
    update o;
    Test.stopTest();

    // Com o e-mail configurado em ADV_Configuracao.Padrao, o aviso sai por
    // e-mail e a tarefa de "aviso não enviado" não é criada.
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Task
        WHERE WhatId = :o.Id AND Subject LIKE 'Avisar o Antônio%'
      ],
      'Com destinatário configurado, não há tarefa de falha de aviso.'
    );
  }

  // ------------------------------------------------------- STech Telecom

  @IsTest
  static void steTurmaPreencheHorarioDoPolo() {
    STE_Polo__mdt polo = [
      SELECT STE_Nome_Polo__c, STE_Horario__c
      FROM STE_Polo__mdt
      WHERE STE_Horario__c != NULL
        AND STE_Nome_Polo__c IN ('Barra Funda', 'Itaim Paulista')
      LIMIT 1
    ];
    Opportunity o = novaSteTelecom(conta(), 'Verificação de Antecedentes');
    o.STE_Turma__c = polo.STE_Nome_Polo__c;
    insert o;

    Assert.areEqual(
      polo.STE_Horario__c,
      [SELECT STE_Horario_Turma__c FROM Opportunity WHERE Id = :o.Id]
      .STE_Horario_Turma__c,
      'STE_Preencher_Horario_Por_Polo copia o horário do polo da turma.'
    );
  }

  @IsTest
  static void steDataDaTurmaEspelhaNoContatoDaConta() {
    Id contaId = conta();
    Contact c = new Contact(LastName = 'Candidato flows', AccountId = contaId);
    insert c;

    Opportunity o = novaSteTelecom(contaId, 'Verificação de Antecedentes');
    o.STE_Data_Inicio_Turma__c = Date.today().addDays(10);
    insert o;

    c = [
      SELECT STE_Data_Inicio_Turma__c, STE_Oportunidade_Jornada__c
      FROM Contact
      WHERE Id = :c.Id
    ];
    Assert.areEqual(
      o.STE_Data_Inicio_Turma__c,
      c.STE_Data_Inicio_Turma__c,
      'STE_Espelhar_Turma_No_Contato copia a data da turma para o Contato da Conta.'
    );
    Assert.areEqual(
      o.Id,
      c.STE_Oportunidade_Jornada__c,
      'O Contato aponta para a Oportunidade da jornada.'
    );
  }

  @IsTest
  static void stePreMatriculaCriaEConcluiCadencia() {
    Opportunity o = novaSteTelecom(conta(), 'Pré-Matrícula');
    o.STE_Data_Inicio_Turma__c = Date.today().addDays(10);
    insert o;

    List<Task> cadencia = [
      SELECT Id
      FROM Task
      WHERE WhatId = :o.Id AND STE_Cadencia_PreAula__c = TRUE
    ];
    Assert.isFalse(
      cadencia.isEmpty(),
      'STE_Cadencia_Criar cria as tarefas da cadência pré-aula.'
    );
    Assert.isTrue(
      [SELECT STE_Cadencia_Criada__c FROM Opportunity WHERE Id = :o.Id]
      .STE_Cadencia_Criada__c,
      'A Oportunidade fica marcada com a cadência criada.'
    );

    for (Task t : cadencia) {
      t.Status = 'Completed';
    }
    update cadencia;

    Assert.isTrue(
      [SELECT STE_Cadencia_Concluida__c FROM Opportunity WHERE Id = :o.Id]
      .STE_Cadencia_Concluida__c,
      'STE_Cadencia_Concluir marca a cadência como concluída quando todas fecham.'
    );
  }

  @IsTest
  static void steCompareceuNaEfetivacaoViraGanho() {
    Opportunity o = novaSteTelecom(conta(), 'Efetivação');
    o.STE_Comparecimento__c = 'Compareceu';
    insert o;

    Assert.areEqual(
      'Ganho',
      [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
      'STE_Comparecimento_Ganho leva para Ganho quem compareceu.'
    );
  }

  @IsTest
  static void steNaoCompareceuCriaProtocolo() {
    Opportunity o = novaSteTelecom(conta(), 'Efetivação');
    o.STE_Comparecimento__c = 'Não compareceu';
    insert o;

    Assert.isTrue(
      [SELECT STE_Protocolo_Criado__c FROM Opportunity WHERE Id = :o.Id]
      .STE_Protocolo_Criado__c,
      'STE_Comparecimento_Protocolo marca o protocolo como criado.'
    );
    Assert.isTrue(
      [
        SELECT COUNT()
        FROM Task
        WHERE WhatId = :o.Id AND Subject LIKE 'Protocolo não comparecimento%'
      ] > 0,
      'O protocolo de não comparecimento gera as tarefas de ligação.'
    );
  }
}
