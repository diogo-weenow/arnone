/**
 * Resolve o candidato e a classificação de fila a partir da MessagingSession.
 *
 * A identificação segue uma cascata, da mais específica para a mais ampla:
 *   1. Sessao   — Lead/Contato com STE_MessagingSession_Id__c desta conversa
 *   2. Vinculo  — MessagingEndUser.ContactId / .LeadId, gravado em conversas anteriores
 *   3. Telefone — STE_Telefone_E164__c igual ao telefone do MessagingEndUser
 *
 * A classificação de fila é devolvida nos três passos, para que quem já se
 * qualificou seja roteado direto à fila em vez de responder o formulário do bot
 * outra vez. A única exceção é Fria fora da conversa atual: quem ainda não foi
 * esquentado volta para o bot, que segue a qualificação pela conversa.
 */
public without sharing class STE_RoutingResolver {
  private static final String FILA_FRIA = 'Fria';
  private static final String ORIGEM_SESSAO = 'Sessao';
  private static final String ORIGEM_VINCULO = 'Vinculo';
  private static final String ORIGEM_TELEFONE = 'Telefone';

  public class Entrada {
    @InvocableVariable(label='ID da sessão' required=true)
    public String sessionId;
  }

  public class Resultado {
    @InvocableVariable(label='Classificação')
    public String classificacao;

    @InvocableVariable(label='ID do candidato')
    public String recordId;

    @InvocableVariable(label='Tipo do candidato')
    public String tipoRegistro;

    @InvocableVariable(label='Candidato encontrado')
    public Boolean encontrado;

    @InvocableVariable(label='Origem do reconhecimento')
    public String origemMatch;

    @InvocableVariable(label='Status do Lead')
    public String statusLead;

    @InvocableVariable(label='Faixa etária registrada')
    public String faixaEtaria;

    @InvocableVariable(label='Posse da CNH registrada')
    public String possuiCnh;

    @InvocableVariable(label='CNH já enviada')
    public Boolean cnhEnviada;

    private Resultado() {
      encontrado = false;
      cnhEnviada = false;
    }
  }

  @InvocableMethod(
    label='Resolver classificação STech pela sessão'
    description='Identifica o candidato pela sessão, pelo vínculo do telefone ou pelo telefone, e devolve a classificação de fila do cadastro, exceto Fria fora da conversa atual.'
    category='Stech Telecom'
  )
  public static List<Resultado> resolver(List<Entrada> entradas) {
    List<Resultado> resultados = new List<Resultado>();
    if (entradas == null || entradas.isEmpty())
      return resultados;

    Set<Id> sessoes = new Set<Id>();
    for (Entrada entrada : entradas) {
      Id sessao = sessaoValida(entrada == null ? null : entrada.sessionId);
      if (sessao != null)
        sessoes.add(sessao);
      resultados.add(new Resultado());
    }
    if (sessoes.isEmpty())
      return resultados;

    Map<Id, MessagingSession> sessaoPorId = new Map<Id, MessagingSession>(
      [
        SELECT
          Id,
          MessagingEndUserId,
          MessagingEndUser.MessagingPlatformKey,
          MessagingEndUser.LeadId,
          MessagingEndUser.ContactId
        FROM MessagingSession
        WHERE Id IN :sessoes
      ]
    );

    Set<String> chavesSessao = new Set<String>();
    Set<Id> leadsVinculados = new Set<Id>();
    Set<Id> contatosVinculados = new Set<Id>();
    Set<String> telefones = new Set<String>();
    for (MessagingSession sessao : sessaoPorId.values()) {
      chavesSessao.add(String.valueOf(sessao.Id));
      if (sessao.MessagingEndUserId == null)
        continue;
      if (sessao.MessagingEndUser.LeadId != null)
        leadsVinculados.add(sessao.MessagingEndUser.LeadId);
      if (sessao.MessagingEndUser.ContactId != null)
        contatosVinculados.add(sessao.MessagingEndUser.ContactId);
      telefones.addAll(
        STE_Telefone.variantes(sessao.MessagingEndUser.MessagingPlatformKey)
      );
    }

    Map<Id, Lead> leads = new Map<Id, Lead>(
      [
        SELECT
          Id,
          Status,
          STE_CNH_Enviada__c,
          STE_Classificacao_Fila__c,
          STE_Faixa_Etaria__c,
          STE_MessagingSession_Id__c,
          STE_Possui_CNH__c,
          STE_Telefone_E164__c
        FROM Lead
        WHERE
          IsConverted = FALSE
          AND (STE_MessagingSession_Id__c IN :chavesSessao
          OR Id IN :leadsVinculados
          OR STE_Telefone_E164__c IN :telefones)
        ORDER BY LastModifiedDate DESC
      ]
    );

    Map<Id, Contact> contatos = new Map<Id, Contact>(
      [
        SELECT
          Id,
          STE_CNH_Enviada__c,
          STE_Classificacao_Fila__c,
          STE_Faixa_Etaria__c,
          STE_MessagingSession_Id__c,
          STE_Possui_CNH__c,
          STE_Telefone_E164__c
        FROM Contact
        WHERE
          STE_MessagingSession_Id__c IN :chavesSessao
          OR Id IN :contatosVinculados
          OR STE_Telefone_E164__c IN :telefones
        ORDER BY LastModifiedDate DESC
      ]
    );

    Map<String, Lead> leadPorSessao = new Map<String, Lead>();
    Map<String, Lead> leadPorTelefone = new Map<String, Lead>();
    for (Lead l : leads.values()) {
      if (l.STE_MessagingSession_Id__c != null) {
        primeiroVence(leadPorSessao, l.STE_MessagingSession_Id__c, l);
      }
      for (String variante : STE_Telefone.variantes(l.STE_Telefone_E164__c)) {
        primeiroVence(leadPorTelefone, variante, l);
      }
    }

    Map<String, Contact> contatoPorSessao = new Map<String, Contact>();
    Map<String, Contact> contatoPorTelefone = new Map<String, Contact>();
    for (Contact c : contatos.values()) {
      if (c.STE_MessagingSession_Id__c != null) {
        primeiroVence(contatoPorSessao, c.STE_MessagingSession_Id__c, c);
      }
      for (String variante : STE_Telefone.variantes(c.STE_Telefone_E164__c)) {
        primeiroVence(contatoPorTelefone, variante, c);
      }
    }

    Map<Id, Resultado> vinculoPorEndUser = new Map<Id, Resultado>();

    for (Integer i = 0; i < entradas.size(); i++) {
      Id chave = sessaoValida(
        entradas[i] == null ? null : entradas[i].sessionId
      );
      MessagingSession sessao = chave == null ? null : sessaoPorId.get(chave);
      if (sessao == null)
        continue;

      Resultado resultado = resultados[i];
      String chaveTexto = String.valueOf(chave);

      if (leadPorSessao.containsKey(chaveTexto)) {
        preencher(resultado, leadPorSessao.get(chaveTexto), ORIGEM_SESSAO);
      } else if (contatoPorSessao.containsKey(chaveTexto)) {
        preencher(resultado, contatoPorSessao.get(chaveTexto), ORIGEM_SESSAO);
      } else if (
        sessao.MessagingEndUserId != null &&
        contatos.containsKey(sessao.MessagingEndUser.ContactId)
      ) {
        preencher(
          resultado,
          contatos.get(sessao.MessagingEndUser.ContactId),
          ORIGEM_VINCULO
        );
      } else if (
        sessao.MessagingEndUserId != null &&
        leads.containsKey(sessao.MessagingEndUser.LeadId)
      ) {
        preencher(
          resultado,
          leads.get(sessao.MessagingEndUser.LeadId),
          ORIGEM_VINCULO
        );
      } else if (sessao.MessagingEndUserId != null) {
        String telefone = primeiraVariante(
          sessao.MessagingEndUser.MessagingPlatformKey,
          contatoPorTelefone.keySet()
        );
        if (telefone != null) {
          preencher(
            resultado,
            contatoPorTelefone.get(telefone),
            ORIGEM_TELEFONE
          );
        } else {
          telefone = primeiraVariante(
            sessao.MessagingEndUser.MessagingPlatformKey,
            leadPorTelefone.keySet()
          );
          if (telefone != null) {
            preencher(resultado, leadPorTelefone.get(telefone), ORIGEM_TELEFONE);
          }
        }
      }

      if (resultado.encontrado == true && sessao.MessagingEndUserId != null) {
        vinculoPorEndUser.put(sessao.MessagingEndUserId, resultado);
      }
    }

    gravarVinculos(vinculoPorEndUser, sessaoPorId);
    return resultados;
  }

  /**
   * Mantém o vínculo do telefone atualizado, para que a próxima conversa seja
   * reconhecida pelo passo 1 da cascata sem depender de varredura por telefone.
   */
  private static void gravarVinculos(
    Map<Id, Resultado> vinculoPorEndUser,
    Map<Id, MessagingSession> sessaoPorId
  ) {
    if (vinculoPorEndUser.isEmpty())
      return;

    Map<Id, MessagingEndUser> atuais = new Map<Id, MessagingEndUser>();
    for (MessagingSession sessao : sessaoPorId.values()) {
      if (
        sessao.MessagingEndUserId != null &&
        vinculoPorEndUser.containsKey(sessao.MessagingEndUserId)
      ) {
        atuais.put(sessao.MessagingEndUserId, sessao.MessagingEndUser);
      }
    }

    List<MessagingEndUser> alterar = new List<MessagingEndUser>();
    for (Id endUserId : atuais.keySet()) {
      MessagingEndUser atual = atuais.get(endUserId);
      Resultado resultado = vinculoPorEndUser.get(endUserId);
      Id registro = (Id) resultado.recordId;
      if (resultado.tipoRegistro == 'Contact') {
        if (atual.ContactId != registro) {
          alterar.add(
            new MessagingEndUser(
              Id = endUserId,
              ContactId = registro,
              LeadId = null
            )
          );
        }
      } else if (atual.ContactId == null && atual.LeadId != registro) {
        alterar.add(new MessagingEndUser(Id = endUserId, LeadId = registro));
      }
    }
    if (!alterar.isEmpty())
      Database.update(alterar, false);
  }

  /**
   * Classificação devolvida ao roteamento.
   *
   * Reconhecido pela própria conversa, vale o que está gravado. Reconhecido pelo
   * vínculo ou pelo telefone — quem está voltando —, a classificação também vale:
   * quem já se qualificou vai direto para a fila, sem repetir o formulário do bot.
   *
   * Fria fica de fora de propósito: só vai direto ao analista quem já foi
   * esquentado antes (Morna ou Quente). O Lead Fria — o que entrou pelo formulário
   * do site ou foi recusado pelos critérios da turma — volta para o bot, que segue
   * a qualificação pela conversa.
   */
  private static String classificacaoDeRetorno(
    String classificacao,
    String origem
  ) {
    if (origem == ORIGEM_SESSAO)
      return classificacao;
    return FILA_FRIA.equalsIgnoreCase(classificacao) ? null : classificacao;
  }

  private static void preencher(Resultado resultado, Lead l, String origem) {
    resultado.encontrado = true;
    resultado.origemMatch = origem;
    resultado.recordId = String.valueOf(l.Id);
    resultado.tipoRegistro = 'Lead';
    resultado.statusLead = l.Status;
    resultado.faixaEtaria = l.STE_Faixa_Etaria__c;
    resultado.possuiCnh = l.STE_Possui_CNH__c;
    resultado.cnhEnviada = l.STE_CNH_Enviada__c == true;
    resultado.classificacao = classificacaoDeRetorno(l.STE_Classificacao_Fila__c, origem);
  }

  private static void preencher(Resultado resultado, Contact c, String origem) {
    resultado.encontrado = true;
    resultado.origemMatch = origem;
    resultado.recordId = String.valueOf(c.Id);
    resultado.tipoRegistro = 'Contact';
    resultado.faixaEtaria = c.STE_Faixa_Etaria__c;
    resultado.possuiCnh = c.STE_Possui_CNH__c;
    resultado.cnhEnviada = c.STE_CNH_Enviada__c == true;
    resultado.classificacao = classificacaoDeRetorno(c.STE_Classificacao_Fila__c, origem);
  }

  private static void primeiroVence(
    Map<String, Lead> destino,
    String chave,
    Lead valor
  ) {
    if (!destino.containsKey(chave))
      destino.put(chave, valor);
  }

  private static void primeiroVence(
    Map<String, Contact> destino,
    String chave,
    Contact valor
  ) {
    if (!destino.containsKey(chave))
      destino.put(chave, valor);
  }

  /** Devolve a primeira variante do telefone presente no conjunto de chaves. */
  private static String primeiraVariante(
    String telefone,
    Set<String> disponiveis
  ) {
    for (String variante : STE_Telefone.variantes(telefone)) {
      if (disponiveis.contains(variante))
        return variante;
    }
    return null;
  }


  private static Id sessaoValida(String valor) {
    if (String.isBlank(valor))
      return null;
    try {
      Id candidato = (Id) valor.trim();
      return candidato.getSObjectType() == MessagingSession.SObjectType
        ? candidato
        : null;
    } catch (Exception e) {
      return null;
    }
  }
}