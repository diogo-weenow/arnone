/**
 * Marca no Lead em que pergunta do Assistente Stech Telecom o candidato está,
 * para que o time saiba onde cada pessoa parou sem precisar abrir a conversa.
 *
 * Chamada por passos invisíveis do bot, antes de cada pergunta. Nada do que
 * o candidato vê muda por causa desta classe.
 *
 * Só grava quando já existe um Lead — o caso normal, porque o candidato chega
 * ao WhatsApp depois de preencher o formulário do site. Quem chega direto pelo
 * WhatsApp só ganha Lead no fim do fluxo, pela STE_BotRegistrarCandidato, e aí
 * a etapa é gravada como Concluído por ela.
 *
 * Nunca lança exceção: uma falha aqui não pode derrubar a conversa do
 * candidato, que é o que de fato importa.
 */
public without sharing class STE_BotRegistrarEtapa {
  /**
   * Os toques de retomada são contados em horas ÚTEIS, não corridas: quem para
   * numa sexta à noite é chamado na segunda de manhã, e não de madrugada.
   * O cálculo sai daqui porque é neste ponto que sabemos a hora exata em que o
   * candidato parou; o flow de retomada só dispara no momento já calculado.
   */
  private static final String HORARIO_STECH = 'Stech - Business Hours';
  private static final Long UMA_HORA = 60L * 60L * 1000L;
  private static final Map<String, Long> ESPERA_POR_TOQUE = new Map<String, Long>{
    'STE_Retomada_1_Em__c' => 1L * UMA_HORA
  };

  public class Entrada {
    /**
     * Não é obrigatório de propósito: um valor vazio faz a classe não gravar
     * nada, enquanto `required=true` derrubaria o diálogo inteiro do bot.
     */
    @InvocableVariable(
      label='Etapa'
      description='Valor da lista STE_Etapa_Bot__c, por exemplo "Aguardando e-mail".'
    )
    public String etapa;

    @InvocableVariable(label='Id do usuário final de mensageria')
    public String endUserId;
  }

  public class Resultado {
    @InvocableVariable(label='Gravado')
    public Boolean gravado;

    @InvocableVariable(label='Id do Lead')
    public String recordId;
  }

  @InvocableMethod(
    label='Registrar etapa da conversa — Stech Telecom'
    description='Grava no Lead em qual pergunta do bot o candidato está.'
    category='Stech Telecom'
  )
  public static List<Resultado> registrar(List<Entrada> entradas) {
    List<Resultado> saida = new List<Resultado>();
    if (entradas == null || entradas.isEmpty()) {
      return saida;
    }

    for (Integer i = 0; i < entradas.size(); i++) {
      Resultado r = new Resultado();
      r.gravado = false;
      saida.add(r);
    }

    try {
      aplicar(entradas, saida);
    } catch (Exception e) {
      // A conversa continua mesmo que a marcação falhe.
      System.debug(
        LoggingLevel.ERROR,
        'STE_BotRegistrarEtapa: ' + e.getMessage()
      );
    }
    return saida;
  }

  private static void aplicar(List<Entrada> entradas, List<Resultado> saida) {
    Map<Id, MessagingEndUser> endUsers = carregarEndUsers(entradas);
    if (endUsers.isEmpty()) {
      return;
    }

    Set<Id> leadsVinculados = new Set<Id>();
    Set<String> telefones = new Set<String>();
    for (MessagingEndUser eu : endUsers.values()) {
      if (eu.LeadId != null) {
        leadsVinculados.add(eu.LeadId);
      }
      telefones.addAll(STE_Telefone.variantes(eu.MessagingPlatformKey));
    }
    if (leadsVinculados.isEmpty() && telefones.isEmpty()) {
      return;
    }

    Map<Id, Lead> leads = new Map<Id, Lead>(
      [
        SELECT Id, STE_Telefone_E164__c, STE_Etapa_Bot__c
        FROM Lead
        WHERE
          IsConverted = FALSE
          AND (Id IN :leadsVinculados
          OR STE_Telefone_E164__c IN :telefones)
        ORDER BY LastModifiedDate DESC
      ]
    );
    if (leads.isEmpty()) {
      return;
    }

    Map<String, Lead> leadPorTelefone = new Map<String, Lead>();
    for (Lead l : leads.values()) {
      for (String variante : STE_Telefone.variantes(l.STE_Telefone_E164__c)) {
        if (!leadPorTelefone.containsKey(variante)) {
          leadPorTelefone.put(variante, l);
        }
      }
    }

    Datetime agora = System.now();
    Map<Id, Lead> aAtualizar = new Map<Id, Lead>();
    for (Integer i = 0; i < entradas.size(); i++) {
      Entrada entrada = entradas[i];
      String etapa = texto(entrada == null ? null : entrada.etapa);
      if (etapa == null) {
        continue;
      }

      Lead alvo = localizar(entrada, endUsers, leads, leadPorTelefone);
      if (alvo == null || etapa.equals(alvo.STE_Etapa_Bot__c)) {
        // Sem Lead, ou o candidato voltou para a mesma pergunta: nada a fazer.
        continue;
      }

      Lead upd = aAtualizar.containsKey(alvo.Id)
        ? aAtualizar.get(alvo.Id)
        : new Lead(Id = alvo.Id);
      upd.STE_Etapa_Bot__c = etapa;
      upd.STE_Etapa_Bot_Desde__c = agora;
      agendarRetomadas(upd, agora);
      aAtualizar.put(alvo.Id, upd);

      saida[i].gravado = true;
      saida[i].recordId = alvo.Id;
    }

    if (!aAtualizar.isEmpty()) {
      update aAtualizar.values();
    }
  }

  private static Lead localizar(
    Entrada entrada,
    Map<Id, MessagingEndUser> endUsers,
    Map<Id, Lead> leads,
    Map<String, Lead> leadPorTelefone
  ) {
    Id endUserId = idDoTipo(
      entrada == null ? null : entrada.endUserId,
      MessagingEndUser.SObjectType
    );
    if (endUserId == null) {
      return null;
    }
    MessagingEndUser eu = endUsers.get(endUserId);
    if (eu == null) {
      return null;
    }
    if (eu.LeadId != null && leads.containsKey(eu.LeadId)) {
      return leads.get(eu.LeadId);
    }
    for (String variante : STE_Telefone.variantes(eu.MessagingPlatformKey)) {
      if (leadPorTelefone.containsKey(variante)) {
        return leadPorTelefone.get(variante);
      }
    }
    return null;
  }

  private static Map<Id, MessagingEndUser> carregarEndUsers(
    List<Entrada> entradas
  ) {
    Set<Id> ids = new Set<Id>();
    for (Entrada entrada : entradas) {
      if (entrada == null) {
        continue;
      }
      Id endUser = idDoTipo(entrada.endUserId, MessagingEndUser.SObjectType);
      if (endUser != null) {
        ids.add(endUser);
      }
    }
    if (ids.isEmpty()) {
      return new Map<Id, MessagingEndUser>();
    }
    return new Map<Id, MessagingEndUser>(
      [
        SELECT Id, LeadId, MessagingPlatformKey
        FROM MessagingEndUser
        WHERE Id IN :ids
      ]
    );
  }

  /**
   * Marca quando cada toque de retomada deve sair, contando só o tempo dentro
   * do horário comercial. Se o horário não estiver configurado, deixa os campos
   * em branco: é melhor não chamar ninguém do que chamar de madrugada.
   */
  private static void agendarRetomadas(Lead destino, Datetime base) {
    Id horarioId = horarioComercial();
    if (horarioId == null) {
      return;
    }
    for (String campo : ESPERA_POR_TOQUE.keySet()) {
      destino.put(
        campo,
        BusinessHours.add(horarioId, base, ESPERA_POR_TOQUE.get(campo))
      );
    }
  }

  private static Id horarioCache;
  private static Boolean horarioConsultado = false;

  private static Id horarioComercial() {
    if (!horarioConsultado) {
      horarioConsultado = true;
      List<BusinessHours> encontrados = [
        SELECT Id
        FROM BusinessHours
        WHERE Name = :HORARIO_STECH AND IsActive = TRUE
        LIMIT 1
      ];
      horarioCache = encontrados.isEmpty() ? null : encontrados[0].Id;
    }
    return horarioCache;
  }

  private static Id idDoTipo(String valor, Schema.SObjectType tipoEsperado) {
    String limpo = texto(valor);
    if (limpo == null) {
      return null;
    }
    try {
      Id candidato = (Id) limpo;
      return candidato.getSObjectType() == tipoEsperado ? candidato : null;
    } catch (Exception e) {
      return null;
    }
  }

  private static String texto(String valor) {
    if (String.isBlank(valor)) {
      return null;
    }
    String limpo = valor.trim();
    return limpo.length() == 0 ? null : limpo;
  }
}