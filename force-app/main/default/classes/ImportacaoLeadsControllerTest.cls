/**
 * Importação de leads — testes da orquestração (controller).
 *
 * Permissão por persona (getBus/getPerfis/iniciarLote com System.runAs),
 * classificação SOL por CNPJ (13 dígitos, DV, alfanumérico, notação científica,
 * convertido, duplicado, RT do perfil), escolha no múltiplo e classificação STE
 * por CPF (formatos, JA_CONTATO, SEM_MATCH sem criação, RT do perfil).
 *
 * O usuário que roda os testes recebe Base + SOL + STE no @TestSetup. As
 * personas restritas usam o perfil "Minimum Access - Salesforce".
 */
@IsTest
private class ImportacaoLeadsControllerTest {
  @TestSetup
  static void semear() {
    ImportacaoLeadsTestFactory.operador(
      new List<String>{
        ImportacaoLeadsTestFactory.PS_BASE,
        ImportacaoLeadsTestFactory.PS_SOL,
        ImportacaoLeadsTestFactory.PS_STE
      }
    );
    ImportacaoLeadsTestFactory.semearSingleton();
  }

  private static User operador() {
    return ImportacaoLeadsTestFactory.operadorDoSetup();
  }

  // ---------------------------------------------------------------- helpers

  private static ImportacaoLeadsController.LinhaDTO dto(
    Integer n,
    String chave,
    Map<String, String> v
  ) {
    ImportacaoLeadsController.LinhaDTO d = new ImportacaoLeadsController.LinhaDTO();
    d.numeroLinha = n;
    d.chave = chave;
    d.valores = v;
    return d;
  }

  private static Map<String, String> valoresSol(String funcionarios) {
    return new Map<String, String>{
      'NumberOfEmployees' => funcionarios,
      'Company' => 'Empresa Importação',
      'LastName' => 'Contato Importação'
    };
  }

  /** Cria o lote, envia as linhas como JSON string (igual à LWC) e classifica. */
  private static ImportacaoLeadsController.PreviewDTO carregar(
    String perfil,
    List<ImportacaoLeadsController.LinhaDTO> linhas
  ) {
    Id lote = ImportacaoLeadsController.iniciarLote(perfil, 'f.csv', linhas.size(), '{}');
    ImportacaoLeadsController.adicionarLinhas(lote, JSON.serialize(linhas));
    return ImportacaoLeadsController.classificar(lote);
  }

  private static Map<Integer, Importacao_Linha__c> linhasPorNumero(Id loteId) {
    Map<Integer, Importacao_Linha__c> m = new Map<Integer, Importacao_Linha__c>();
    for (Importacao_Linha__c l : [
      SELECT
        Numero_Linha__c,
        Resultado_Match__c,
        Motivo_Invalido__c,
        Acao__c,
        Leads_Alvo__c,
        Erro__c,
        Lead_Resultante__c,
        Resultado_Processamento__c
      FROM Importacao_Linha__c
      WHERE Lote__c = :loteId
    ]) {
      m.put(l.Numero_Linha__c.intValue(), l);
    }
    return m;
  }

  private static Boolean lancou(String perfil, String trecho) {
    try {
      ImportacaoLeadsController.iniciarLote(perfil, 'f.csv', 1, '{}');
    } catch (AuraHandledException e) {
      Assert.isTrue(
        e.getMessage().containsIgnoreCase(trecho),
        'Mensagem deveria conter "' + trecho + '": ' + e.getMessage()
      );
      return true;
    }
    return false;
  }

  private static List<String> valores(List<ImportacaoLeadsController.BuDTO> bus) {
    List<String> l = new List<String>();
    for (ImportacaoLeadsController.BuDTO b : bus) {
      l.add(b.value);
    }
    return l;
  }

  // ---------------------------------------------------------------- permissão (6, 7, 8)

  @IsTest
  static void soPsBaseNaoVeBuENaoIniciaLote() {
    User u = ImportacaoLeadsTestFactory.persona(
      'base',
      new List<String>{ ImportacaoLeadsTestFactory.PS_BASE }
    );
    System.runAs(u) {
      Assert.areEqual(0, ImportacaoLeadsController.getBus().size(), 'Só o PS base não libera BU.');
      Assert.areEqual(
        0,
        ImportacaoLeadsController.getPerfis('SOL').size(),
        'Só o PS base não libera perfil.'
      );
      Assert.isTrue(
        lancou('SOL_Generico', 'permissão'),
        'iniciarLote deveria lançar sem a custom permission.'
      );
    }
  }

  @IsTest
  static void busPorPersonaEsgEScoNuncaAparecem() {
    User sol = ImportacaoLeadsTestFactory.persona(
      'sol',
      new List<String>{ ImportacaoLeadsTestFactory.PS_BASE, ImportacaoLeadsTestFactory.PS_SOL }
    );
    User todos = ImportacaoLeadsTestFactory.persona(
      'todos',
      new List<String>{
        ImportacaoLeadsTestFactory.PS_BASE,
        ImportacaoLeadsTestFactory.PS_SOL,
        ImportacaoLeadsTestFactory.PS_STE,
        ImportacaoLeadsTestFactory.PS_ESG,
        ImportacaoLeadsTestFactory.PS_SCO
      }
    );
    System.runAs(sol) {
      Assert.areEqual(
        new List<String>{ 'SOL' },
        valores(ImportacaoLeadsController.getBus()),
        'Base + SOL deveria ver só SOL.'
      );
      List<ImportacaoLeadsController.PerfilDTO> ps = ImportacaoLeadsController.getPerfis('SOL');
      Assert.areEqual(1, ps.size(), 'Um perfil SOL.');
      Assert.areEqual('SOL_Generico', ps[0].developerName, 'Perfil SOL genérico.');
      Assert.isFalse(ps[0].mapeamentos.isEmpty(), 'Perfil traz a matriz de campos.');
    }
    System.runAs(todos) {
      Assert.areEqual(
        new List<String>{ 'SOL', 'STE' },
        valores(ImportacaoLeadsController.getBus()),
        'Com todos os PS: SOL e STE; ESG e SCO são inativos e nunca aparecem.'
      );
      Assert.areEqual(0, ImportacaoLeadsController.getPerfis('ESG').size(), 'ESG inativo.');
      Assert.areEqual(0, ImportacaoLeadsController.getPerfis('SCO').size(), 'SCO inativo.');
    }
  }

  @IsTest
  static void perfilInativoLancaExcecao() {
    ImportacaoLeadsTestFactory.atribuirPs(
      UserInfo.getUserId(),
      new List<String>{ ImportacaoLeadsTestFactory.PS_ESG }
    );
    Assert.isTrue(lancou('ESG_Generico', 'inativo'), 'ESG inativo deveria lançar.');
    Assert.isTrue(lancou('Perfil_Que_Nao_Existe', 'não encontrado'), 'Perfil inexistente lança.');
  }

  // ---------------------------------------------------------------- SOL (1, 2, 3, 4, 13, 14, 11)

  @IsTest
  static void solClassificaBaldesPorCnpj() {
    System.runAs(operador()) {
      ImportacaoLeadsTestFactory.montarFila(2);
      ImportacaoLeadsTestFactory.aplicarOverridesSol();
      Lead zero = ImportacaoLeadsTestFactory.novoLeadSOL('Zero', 'Emp Zero', ImportacaoLeadsTestFactory.CNPJ_ZERO);
      Lead alfa = ImportacaoLeadsTestFactory.novoLeadSOL('Alfa', 'Emp Alfa', ImportacaoLeadsTestFactory.CNPJ_ALFA);

      Test.startTest();
      ImportacaoLeadsController.PreviewDTO pv = carregar(
        'SOL_Generico',
        new List<ImportacaoLeadsController.LinhaDTO>{
          dto(1, '1234567000195', valoresSol('10')), // 13 dígitos (cenário 1)
          dto(2, '11.222.333/0001-82', valoresSol('10')), // DV inválido (2)
          dto(3, '12.abc.345/01de-35', valoresSol('10')), // alfanumérico minúsculo (3)
          dto(4, '4,53413E+13', valoresSol('10')), // notação científica (4)
          dto(5, ImportacaoLeadsTestFactory.CNPJ_B, valoresSol('10')), // sem match
          dto(6, ImportacaoLeadsTestFactory.CNPJ_B, valoresSol('20')), // duplicado (14)
          dto(7, '', valoresSol('10')) // chave ausente
        }
      );
      Test.stopTest();

      Map<Integer, Importacao_Linha__c> l = linhasPorNumero(pv.loteId);
      Assert.areEqual('MATCH_UNICO', l.get(1).Resultado_Match__c, '13 dígitos completado casa.');
      Assert.isTrue(l.get(1).Leads_Alvo__c.contains(zero.Id), 'Casou o lead do CNPJ com zero.');
      Assert.areEqual('INVALIDO', l.get(2).Resultado_Match__c, 'DV inválido.');
      Assert.areEqual('DV_INVALIDO', l.get(2).Motivo_Invalido__c, 'Motivo DV_INVALIDO.');
      Assert.areEqual('MATCH_UNICO', l.get(3).Resultado_Match__c, 'Alfanumérico minúsculo casa.');
      Assert.isTrue(l.get(3).Leads_Alvo__c.contains(alfa.Id), 'Casou o lead alfanumérico.');
      Assert.areEqual('INVALIDO', l.get(4).Resultado_Match__c, 'Notação científica.');
      Assert.areEqual('NOTACAO_CIENTIFICA', l.get(4).Motivo_Invalido__c, 'Motivo NOTACAO_CIENTIFICA.');
      Assert.areEqual('SEM_MATCH', l.get(5).Resultado_Match__c, 'Sem match.');
      Assert.areEqual('CRIAR', l.get(5).Acao__c, 'SOL cria sem match.');
      Assert.areEqual('DUPLICADO_NO_ARQUIVO', l.get(6).Resultado_Match__c, 'Segunda ocorrência.');
      Assert.areEqual('IGNORAR', l.get(6).Acao__c, 'Duplicado ignorado.');
      Assert.areEqual('CHAVE_AUSENTE', l.get(7).Motivo_Invalido__c, 'Chave ausente.');
      Assert.areEqual(2, pv.matchUnico, 'Dois matches únicos.');
      Assert.areEqual(3, pv.invalido, 'Três inválidos.');
      Assert.areEqual(1, pv.semMatch, 'Um sem match.');
      Assert.areEqual(1, pv.duplicado, 'Um duplicado.');
    }
  }

  @IsTest
  static void solConvertidoEhIgnorado() {
    System.runAs(operador()) {
      ImportacaoLeadsTestFactory.montarFila(2);
      ImportacaoLeadsTestFactory.aplicarOverridesSol();
      Lead c = ImportacaoLeadsTestFactory.novoLeadSOL('Conv', 'Emp C', ImportacaoLeadsTestFactory.CNPJ_A);
      update new Lead(Id = c.Id, SOL_Status_Procuracao__c = 'Recebida');
      Database.LeadConvert lc = new Database.LeadConvert();
      lc.setLeadId(c.Id);
      lc.setConvertedStatus(
        [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = TRUE LIMIT 1].MasterLabel
      );
      lc.setDoNotCreateOpportunity(true);
      Database.convertLead(lc);

      Test.startTest();
      ImportacaoLeadsController.PreviewDTO pv = carregar(
        'SOL_Generico',
        new List<ImportacaoLeadsController.LinhaDTO>{
          dto(1, ImportacaoLeadsTestFactory.CNPJ_A, valoresSol('900'))
        }
      );
      Test.stopTest();

      Assert.areEqual(1, pv.convertido, 'Cai no balde CONVERTIDO.');
      Importacao_Linha__c l = linhasPorNumero(pv.loteId).get(1);
      Assert.areEqual('CONVERTIDO', l.Resultado_Match__c, 'Balde CONVERTIDO.');
      Assert.areEqual('IGNORAR', l.Acao__c, 'Convertido é ignorado.');
    }
  }

  @IsTest
  static void solNaoCasaLeadEsgComMesmoCnpj() {
    System.runAs(operador()) {
      ImportacaoLeadsTestFactory.montarFila(2);
      ImportacaoLeadsTestFactory.aplicarOverridesSol();
      Lead esg = ImportacaoLeadsTestFactory.novoLeadCnpj('ESG', 'Esg', 'Emp ESG', ImportacaoLeadsTestFactory.CNPJ_A);
      Lead antes = [SELECT OwnerId, NumberOfEmployees, RecordTypeId FROM Lead WHERE Id = :esg.Id];

      ImportacaoLeadsController.PreviewDTO pv = carregar(
        'SOL_Generico',
        new List<ImportacaoLeadsController.LinhaDTO>{
          dto(1, ImportacaoLeadsTestFactory.CNPJ_A, valoresSol('321'))
        }
      );
      Importacao_Linha__c l = linhasPorNumero(pv.loteId).get(1);
      Assert.areEqual('SEM_MATCH', l.Resultado_Match__c, 'Lead ESG não casa no perfil SOL.');
      Assert.areEqual('CRIAR', l.Acao__c, 'A linha vira criação SOL.');

      Test.startTest();
      ImportacaoLeadsController.confirmar(pv.loteId, null);
      Test.stopTest();

      Lead depois = [SELECT OwnerId, NumberOfEmployees, RecordTypeId FROM Lead WHERE Id = :esg.Id];
      Assert.areEqual(antes.OwnerId, depois.OwnerId, 'Lead ESG intacto (dono).');
      Assert.areEqual(antes.NumberOfEmployees, depois.NumberOfEmployees, 'Lead ESG intacto (campo).');
      Assert.areEqual(antes.RecordTypeId, depois.RecordTypeId, 'Lead ESG intacto (RT).');
      Lead criado = [
        SELECT RecordType.DeveloperName, NumberOfEmployees
        FROM Lead
        WHERE Id = :linhasPorNumero(pv.loteId).get(1).Lead_Resultante__c
      ];
      Assert.areEqual('SOL', criado.RecordType.DeveloperName, 'Lead novo é SOL.');
      Assert.areEqual(321, criado.NumberOfEmployees, 'Lead novo recebeu o campo de criação.');
    }
  }

  // ---------------------------------------------------------------- múltiplo (10)

  @IsTest
  static void solMultiploAtualizaSoSelecionados() {
    System.runAs(operador()) {
      ImportacaoLeadsTestFactory.montarFila(2);
      ImportacaoLeadsTestFactory.aplicarOverridesSol();
      Lead a = ImportacaoLeadsTestFactory.novoLeadSOL('M1', 'Emp M1', ImportacaoLeadsTestFactory.CNPJ_A);
      Lead b = ImportacaoLeadsTestFactory.novoLeadSOL('M2', 'Emp M2', ImportacaoLeadsTestFactory.CNPJ_A);
      update new List<Lead>{
        new Lead(Id = a.Id, NumberOfEmployees = 1),
        new Lead(Id = b.Id, NumberOfEmployees = 1)
      };

      ImportacaoLeadsController.PreviewDTO pv = carregar(
        'SOL_Generico',
        new List<ImportacaoLeadsController.LinhaDTO>{
          dto(1, ImportacaoLeadsTestFactory.CNPJ_A, valoresSol('888'))
        }
      );
      Assert.areEqual(1, pv.matchMultiplo, 'Um múltiplo.');
      Assert.areEqual(2, pv.multiplos[0].leadsAlvo.size(), 'Dois candidatos.');

      ImportacaoLeadsController.SelecaoDTO s = new ImportacaoLeadsController.SelecaoDTO();
      s.linhaId = pv.multiplos[0].linhaId;
      s.acao = 'ATUALIZAR';
      s.leadsSelecionados = new List<Id>{ a.Id };

      Test.startTest();
      Id job = ImportacaoLeadsController.confirmar(
        pv.loteId,
        new List<ImportacaoLeadsController.SelecaoDTO>{ s }
      );
      Test.stopTest();

      Assert.isNotNull(job, 'Batch enfileirado.');
      Assert.areEqual(888, [SELECT NumberOfEmployees FROM Lead WHERE Id = :a.Id].NumberOfEmployees, 'Selecionado atualizado.');
      Assert.areEqual(1, [SELECT NumberOfEmployees FROM Lead WHERE Id = :b.Id].NumberOfEmployees, 'Não selecionado intacto.');
      ImportacaoLeadsController.StatusDTO st = ImportacaoLeadsController.consultarStatus(pv.loteId);
      Assert.areEqual('Concluído', st.status, 'Lote concluído.');
      Assert.areEqual(1, st.qtdAtualizados, 'Uma linha atualizada.');
    }
  }

  @IsTest
  static void confirmarNaoPromoveLinhaACriar() {
    System.runAs(operador()) {
      ImportacaoLeadsTestFactory.montarFila(2);
      ImportacaoLeadsTestFactory.aplicarOverridesSol();
      ImportacaoLeadsController.PreviewDTO pv = carregar(
        'SOL_Generico',
        new List<ImportacaoLeadsController.LinhaDTO>{ dto(1, '123', valoresSol('1')) }
      );
      ImportacaoLeadsController.SelecaoDTO s = new ImportacaoLeadsController.SelecaoDTO();
      s.linhaId = linhasIds(pv.loteId)[0];
      s.acao = 'CRIAR';
      Test.startTest();
      ImportacaoLeadsController.confirmar(
        pv.loteId,
        new List<ImportacaoLeadsController.SelecaoDTO>{ s }
      );
      Test.stopTest();
      Importacao_Linha__c l = linhasPorNumero(pv.loteId).get(1);
      Assert.areEqual('IGNORAR', l.Acao__c, 'Linha inválida não vira CRIAR pelo cliente.');
      Assert.isNull(l.Lead_Resultante__c, 'Nenhum lead criado.');
    }
  }

  private static List<Id> linhasIds(Id loteId) {
    List<Id> ids = new List<Id>();
    for (Importacao_Linha__c l : [SELECT Id FROM Importacao_Linha__c WHERE Lote__c = :loteId]) {
      ids.add(l.Id);
    }
    return ids;
  }

  @IsTest
  static void iniciarLoteBarraAcimaDoMaximo() {
    System.runAs(operador()) {
      Boolean estourou = false;
      try {
        ImportacaoLeadsController.iniciarLote('SOL_Generico', 'grande.csv', 5001, '{}');
      } catch (AuraHandledException e) {
        estourou = true;
        Assert.isTrue(e.getMessage().containsIgnoreCase('máximo'), 'Cita o máximo: ' + e.getMessage());
      }
      Assert.isTrue(estourou, 'Deveria barrar acima de 5000 linhas.');
      Id lote = ImportacaoLeadsController.iniciarLote('SOL_Generico', 'ok.csv', 10, '{"encoding":"utf-8"}');
      Importacao_Lote__c l = [
        SELECT BU__c, Perfil_Importacao__c, Nome_Arquivo__c, Diagnostico_Arquivo__c
        FROM Importacao_Lote__c
        WHERE Id = :lote
      ];
      Assert.areEqual('SOL', l.BU__c, 'BU gravada.');
      Assert.areEqual('SOL_Generico', l.Perfil_Importacao__c, 'Perfil gravado.');
      Assert.areEqual('ok.csv', l.Nome_Arquivo__c, 'Nome do arquivo gravado.');
      Assert.isTrue(l.Diagnostico_Arquivo__c.contains('utf-8'), 'Diagnóstico gravado.');
    }
  }

  // ---------------------------------------------------------------- STE (19, 20, 21, 23)

  @IsTest
  static void steCasaCpfNosDoisFormatosEAtualiza() {
    System.runAs(operador()) {
      // O CPF gravado é só dígitos (VR CPF_Somente_Numeros); a máscara vem do arquivo.
      Lead mascarado = ImportacaoLeadsTestFactory.novoLeadCpf('STE', 'Ste Masc', '12345678909');
      Lead digitos = ImportacaoLeadsTestFactory.novoLeadCpf('STE', 'Ste Dig', ImportacaoLeadsTestFactory.CPF_B);
      update new Lead(Id = mascarado.Id, Email = 'original@arnone.invalid', MobilePhone = null);
      Lead antes = [SELECT OwnerId, RecordTypeId FROM Lead WHERE Id = :mascarado.Id];

      ImportacaoLeadsController.PreviewDTO pv = carregar(
        'STE_Atualizacao_CPF',
        new List<ImportacaoLeadsController.LinhaDTO>{
          dto(1, '123.456.789-09', new Map<String, String>{
            'Email' => 'novo@arnone.invalid',
            'MobilePhone' => '11999998888'
          }),
          dto(2, '987.654.321-00', new Map<String, String>{ 'Phone' => '1133334444' })
        }
      );
      Assert.areEqual(2, pv.matchUnico, 'Os dois CPFs casam, em formatos cruzados.');

      Test.startTest();
      ImportacaoLeadsController.confirmar(pv.loteId, null);
      Test.stopTest();

      Lead m = [SELECT Email, MobilePhone, OwnerId, RecordTypeId FROM Lead WHERE Id = :mascarado.Id];
      Assert.areEqual('original@arnone.invalid', m.Email, 'FILL_BLANK: Email preenchido não muda.');
      Assert.isNotNull(m.MobilePhone, 'FILL_BLANK: MobilePhone vazio é preenchido.');
      Assert.areEqual(antes.OwnerId, m.OwnerId, 'Dono do lead STE não muda.');
      Assert.areEqual(antes.RecordTypeId, m.RecordTypeId, 'RT do lead STE não muda.');
      Assert.isNotNull([SELECT Phone FROM Lead WHERE Id = :digitos.Id].Phone, 'Lead só com dígitos atualizado.');
    }
  }

  @IsTest
  static void steSemMatchJaContatoELeadSolNaoCriam() {
    System.runAs(operador()) {
      insert new Contact(LastName = 'Aluno', CPF__c = ImportacaoLeadsTestFactory.CPF_C);
      Lead sol = new Lead(
        RecordTypeId = ImportacaoLeadsTestFactory.rt('SOL'),
        LastName = 'Sol Cpf',
        Company = 'Emp Sol Cpf',
        CNPJ__c = ImportacaoLeadsDocumento.formatarCnpj(ImportacaoLeadsTestFactory.CNPJ_B),
        CPF__c = ImportacaoLeadsTestFactory.CPF_A,
        Status = ImportacaoLeadsTestFactory.statusPadrao()
      );
      ImportacaoLeadsTestFactory.montarFila(1);
      ImportacaoLeadsTestFactory.aplicarOverridesSol();
      insert sol;
      Integer leadsAntes = [SELECT COUNT() FROM Lead];

      ImportacaoLeadsController.PreviewDTO pv = carregar(
        'STE_Atualizacao_CPF',
        new List<ImportacaoLeadsController.LinhaDTO>{
          dto(1, ImportacaoLeadsTestFactory.CPF_C, new Map<String, String>{ 'Email' => 'a@arnone.invalid' }),
          dto(2, '52998224725', new Map<String, String>{ 'Email' => 'b@arnone.invalid' }),
          dto(3, ImportacaoLeadsTestFactory.CPF_A, new Map<String, String>{ 'Email' => 'c@arnone.invalid' })
        }
      );
      Map<Integer, Importacao_Linha__c> l = linhasPorNumero(pv.loteId);
      Assert.areEqual('JA_CONTATO', l.get(1).Resultado_Match__c, 'CPF de Contact vira JA_CONTATO.');
      Assert.areEqual('IGNORAR', l.get(1).Acao__c, 'JA_CONTATO é ignorado.');
      Assert.areEqual(ImportacaoLeadsController.MSG_JA_CONTATO, l.get(1).Erro__c, 'Mensagem do JA_CONTATO.');
      Assert.areEqual('SEM_MATCH', l.get(2).Resultado_Match__c, 'CPF inexistente.');
      Assert.areEqual('IGNORAR', l.get(2).Acao__c, 'STE não cria.');
      Assert.areEqual(ImportacaoLeadsController.MSG_STE_SEM_MATCH, l.get(2).Erro__c, 'Mensagem do STE.');
      Assert.areEqual('SEM_MATCH', l.get(3).Resultado_Match__c, 'Lead SOL com o mesmo CPF não casa.');
      Assert.areEqual(1, pv.jaContato, 'Um JA_CONTATO.');

      Test.startTest();
      ImportacaoLeadsController.confirmar(pv.loteId, null);
      Test.stopTest();

      Assert.areEqual(leadsAntes, [SELECT COUNT() FROM Lead], 'STE não cria nenhum lead.');
      Assert.isNull([SELECT Email FROM Lead WHERE Id = :sol.Id].Email, 'Lead SOL intacto.');
    }
  }
}
