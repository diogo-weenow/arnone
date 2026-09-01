/**
 * US 05 — Conversão do Lead do funil Stech Telecom em Conta, Contato e
 * Oportunidade.
 *
 * A conversão é manual, acionada por um botão na tela do Lead (premissa 5 da
 * US). O botão é uma ação rápida que roda o flow STE_Converter_Lead, e o flow
 * chama esta classe.
 *
 * Por que Apex e não a ação "Convert Lead" do Flow: o tipo de ação de conversão
 * não é aceito pelo schema de metadados da org (InvocableActionType recusa
 * 'convertLead' no deploy), então a conversão declarativa só seria montável
 * clicando na interface — o que sai do controle do repositório. Em Apex a
 * regra fica versionada e coberta por teste.
 *
 * Conta "Pessoa Física": Person Accounts não está habilitado e a habilitação
 * seria irreversível e valeria para as 5 BUs. Por decisão do cliente
 * (ADR-0008), o candidato vira uma Conta comercial com o record type
 * STE_Pessoa_Fisica, identificada pelo CPF.
 */
public with sharing class STE_ConverterLead {
  @TestVisible
  private static final String RT_CONTA = 'STE_Pessoa_Fisica';
  @TestVisible
  private static final String RT_OPORTUNIDADE = 'STE_Telecom';
  @TestVisible
  private static final String ETAPA_INICIAL = 'Verificação de Antecedentes';
  @TestVisible
  private static final String CODIGO_PRODUTO = 'STE-TEL-001';
  @TestVisible
  private static final String NOME_CATALOGO = 'Catálogo Stech Telecom';

  /** Resultado de uma conversão, devolvido ao flow para montar a tela final. */
  public class Resultado {
    @InvocableVariable(label='Convertido')
    public Boolean convertido;

    @InvocableVariable(label='Mensagem')
    public String mensagem;

    @InvocableVariable(label='Id da Conta')
    public Id contaId;

    @InvocableVariable(label='Id do Contato')
    public Id contatoId;

    @InvocableVariable(label='Id da Oportunidade')
    public Id oportunidadeId;

    private Resultado(Boolean convertido, String mensagem) {
      this.convertido = convertido;
      this.mensagem = mensagem;
    }
  }

  @InvocableMethod(
    label='Converter Lead — Stech Telecom'
    description='Converte o Lead em Conta pessoa física, Contato e Oportunidade do funil Stech Telecom, levando as respostas do chatbot e associando o curso Telecom.'
    category='Stech Telecom'
  )
  public static List<Resultado> converter(List<Id> leadIds) {
    List<Resultado> saida = new List<Resultado>();
    if (leadIds == null || leadIds.isEmpty()) {
      return saida;
    }

    Map<Id, Lead> leads = new Map<Id, Lead>(
      [
        SELECT
          Id,
          Name,
          FirstName,
          LastName,
          Company,
          Email,
          Phone,
          MobilePhone,
          IsConverted,
          CPF__c,
          STE_Genero__c,
          STE_Classificacao_Fila__c,
          STE_CNH_Enviada__c,
          STE_Data_Envio_CNH__c,
          STE_Faixa_Etaria__c,
          STE_Possui_CNH__c
        FROM Lead
        WHERE Id IN :leadIds
      ]
    );

    for (Id leadId : leadIds) {
      Lead l = leads.get(leadId);
      if (l == null) {
        saida.add(new Resultado(false, 'Lead não encontrado.'));
        continue;
      }
      String impedimento = impedimentoPara(l);
      if (impedimento != null) {
        saida.add(new Resultado(false, impedimento));
        continue;
      }
      saida.add(converterUm(l));
    }
    return saida;
  }

  /**
   * Pré-requisitos do cenário 01: só converte quem teve a CNH validada. O CPF
   * é o identificador da pessoa (US 04, regra 4.2) — sem ele não há como
   * montar nem localizar a Conta.
   */
  private static String impedimentoPara(Lead l) {
    if (l.IsConverted) {
      return 'Este Lead já foi convertido.';
    }
    if (l.STE_CNH_Enviada__c != true) {
      return 'A CNH ainda não foi recebida. Marque "CNH enviada" no Lead antes de converter.';
    }
    if (String.isBlank(l.CPF__c)) {
      return 'O CPF está em branco. O atendente precisa registrá-lo a partir da CNH antes da conversão.';
    }
    return null;
  }

  private static Resultado converterUm(Lead l) {
    Savepoint sp = Database.setSavepoint();
    try {
      Id contaId = contaDoCandidato(l);

      Database.LeadConvert pedido = new Database.LeadConvert();
      pedido.setLeadId(l.Id);
      pedido.setConvertedStatus(statusConvertido());
      pedido.setAccountId(contaId);
      pedido.setOpportunityName('Telecom — ' + l.Name);
      pedido.setDoNotCreateOpportunity(false);

      Database.LeadConvertResult r = Database.convertLead(pedido);
      if (!r.isSuccess()) {
        Database.rollback(sp);
        return new Resultado(false, 'A conversão falhou: ' + primeiroErro(r));
      }

      atualizarContato(l, r.getContactId());
      atualizarOportunidade(l, r.getOpportunityId());
      associarCurso(r.getOpportunityId());

      Resultado ok = new Resultado(
        true,
        'Candidato convertido. A Oportunidade nasceu em "' +
          ETAPA_INICIAL +
          '" com o curso Telecom associado.'
      );
      ok.contaId = r.getAccountId();
      ok.contatoId = r.getContactId();
      ok.oportunidadeId = r.getOpportunityId();
      return ok;
    } catch (Exception e) {
      Database.rollback(sp);
      return new Resultado(false, 'A conversão falhou: ' + e.getMessage());
    }
  }

  /**
   * Reaproveita a Conta quando o CPF já tem cadastro. Sem isso, o candidato
   * que volta pelo chatbot geraria uma segunda Conta — e o CPF é unique na
   * Conta, então a conversão simplesmente falharia.
   */
  private static Id contaDoCandidato(Lead l) {
    List<Account> existentes = [
      SELECT Id
      FROM Account
      WHERE STE_CPF__c = :l.CPF__c
      LIMIT 1
    ];
    if (!existentes.isEmpty()) {
      return existentes[0].Id;
    }

    Account nova = new Account(
      Name = l.Name,
      STE_CPF__c = l.CPF__c,
      RecordTypeId = recordTypeId(Account.SObjectType, RT_CONTA)
    );
    insert nova;
    return nova.Id;
  }

  /** Regra 4.2 — o Contato recebe os dados informados durante a conversa. */
  private static void atualizarContato(Lead l, Id contatoId) {
    update new Contact(
      Id = contatoId,
      CPF__c = l.CPF__c,
      STE_WhatsApp__c = String.isNotBlank(l.MobilePhone)
        ? l.MobilePhone
        : l.Phone,
      STE_Genero__c = l.STE_Genero__c,
      STE_Classificacao_Fila__c = l.STE_Classificacao_Fila__c,
      STE_CNH_Enviada__c = l.STE_CNH_Enviada__c,
      STE_Data_Envio_CNH__c = l.STE_Data_Envio_CNH__c
    );
  }

  /**
   * Regra 4.3 e cenário 02 — a Oportunidade carrega as respostas do chatbot,
   * com faixa etária e posse de CNH obrigatoriamente preenchidas. O catálogo
   * restrito é o que atende o cenário 03.
   */
  private static void atualizarOportunidade(Lead l, Id oportunidadeId) {
    update new Opportunity(
      Id = oportunidadeId,
      RecordTypeId = recordTypeId(Opportunity.SObjectType, RT_OPORTUNIDADE),
      StageName = ETAPA_INICIAL,
      Pricebook2Id = catalogo().Id,
      STE_Faixa_Etaria__c = l.STE_Faixa_Etaria__c,
      STE_Possui_CNH__c = l.STE_Possui_CNH__c,
      STE_Genero__c = l.STE_Genero__c,
      STE_Classificacao_Fila__c = l.STE_Classificacao_Fila__c,
      STE_CNH_Enviada__c = l.STE_CNH_Enviada__c,
      STE_Data_Envio_CNH__c = l.STE_Data_Envio_CNH__c
    );
  }

  /**
   * Regra 4.4 — Telecom é o único curso configurado, então já entra
   * associado. Quando Digital, Academia e Liderança existirem, a escolha
   * passa a ser do usuário e este passo sai daqui.
   */
  private static void associarCurso(Id oportunidadeId) {
    List<PricebookEntry> entradas = [
      SELECT Id, UnitPrice
      FROM PricebookEntry
      WHERE
        Pricebook2Id = :catalogo().Id
        AND Product2.ProductCode = :CODIGO_PRODUTO
        AND IsActive = TRUE
      LIMIT 1
    ];
    if (entradas.isEmpty()) {
      return;
    }
    insert new OpportunityLineItem(
      OpportunityId = oportunidadeId,
      PricebookEntryId = entradas[0].Id,
      Quantity = 1,
      UnitPrice = entradas[0].UnitPrice
    );
  }

  private static Pricebook2 catalogoCache;

  private static Pricebook2 catalogo() {
    if (catalogoCache == null) {
      catalogoCache = [
        SELECT Id
        FROM Pricebook2
        WHERE Name = :NOME_CATALOGO
        LIMIT 1
      ];
    }
    return catalogoCache;
  }

  /**
   * O status de conversão não é fixo em código: qualquer valor marcado como
   * "convertido" no LeadStatus serve, e o cliente pode renomear o dele.
   */
  private static String statusConvertidoCache;

  private static String statusConvertido() {
    if (statusConvertidoCache == null) {
      statusConvertidoCache = [
        SELECT MasterLabel
        FROM LeadStatus
        WHERE IsConverted = TRUE
        ORDER BY SortOrder NULLS LAST
        LIMIT 1
      ]
      .MasterLabel;
    }
    return statusConvertidoCache;
  }

  private static Id recordTypeId(Schema.SObjectType tipo, String nomeApi) {
    Schema.RecordTypeInfo info = tipo.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get(nomeApi);
    if (info == null) {
      throw new ConversaoException(
        'Record type ' + nomeApi + ' não encontrado em ' + tipo
      );
    }
    return info.getRecordTypeId();
  }

  private static String primeiroErro(Database.LeadConvertResult r) {
    return r.getErrors().isEmpty()
      ? 'motivo não informado pela plataforma'
      : r.getErrors()[0].getMessage();
  }

  public class ConversaoException extends Exception {
  }
}