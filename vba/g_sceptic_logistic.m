function  [ gx ] = g_sceptic_logistic(x_t,P,u,inG)
% INPUT
% - x : Q-values (2x1)
% - beta : temperature (1x1)
% - u : [useless]
% - inG :
% OUTPUT
% - gx : p(chosen|x_t) or RT

beta = exp(P(1));
%Need to add discrim as an additional param
discrim = 1./(1+exp(-P(2)));
gaussmat=inG.gaussmat;
ntimesteps = inG.ntimesteps;
nbasis = inG.nbasis;

v=x_t(1:nbasis)*ones(1,ntimesteps) .* gaussmat; %use vector outer product to replicate weight vector
u=x_t(nbasis+1:nbasis*2)*ones(1,ntimesteps) .* gaussmat; %Uncertainty is a function of Kalman uncertainties.

v_func = sum(v); %subjective value by timestep as a sum of all basis functions
u_func = sum(u); %vecotr of uncertainty by timestep

%In order to run the multinomial version we still need to compute the
%softmax for both the rt_explore and rt_exploit, then let the sigmoid chose
%an action by giving more weight to a specific softmax.
if strcmp(inG.autocorrelation,'choice_tbf') %This is only when incorporating choice basis functions
    choice = x_t(length(x_t)-nbasis+1:end)*ones(1,ntimesteps) .* gaussmat; %use vector outer product to replicate weight vector
    choice_func = sum(choice); %subjective value of choice by timestep as a sum of all basis functions
    chi =  P(length(P))./100;
    p_rt_exploit = (exp((v_func-max(v_func)+chi.*max(v_func).*choice_func)/beta)) / (sum(exp((v_func-max(v_func)+chi.*max(v_func).*choice_func)/beta))); %Divide by temperature
else
    p_rt_exploit = (exp((v_func-max(v_func))/beta)) / (sum(exp((v_func-max(v_func))/beta))); %Divide by temperature
end

p_rt_explore = (exp((u_func-max(u_func))/beta)) / (sum(exp((u_func-max(u_func))/beta))); %Divide by temperature

%Perform a choice autocorrelation
if strcmp(inG.autocorrelation,'exponential')
    lambda =  1./(1+exp(-P(3))); %% introduce a choice autocorrelation parameter lambda
    chi =  1./(1+exp(-P(4))); %% control the extent of choice autocorrelation
    rt_prev = u(1); %% retrieve previous RT
    
    %%incorporate an exponential choice autocorrelation function for exploit and explore
    p_rt_exploit = p_rt_exploit + chi.*(lambda.^(abs((1:ntimesteps) - rt_prev)));  %% incorporate an exponential choice autocorrelation function
    p_rt_exploit = p_rt_exploit./(sum(p_rt_exploit));  %% re-normalize choice probability so that it adds up to 1
    
    p_rt_explore = p_rt_explore + chi.*(lambda.^(abs((1:ntimesteps) - rt_prev)));  %% incorporate an exponential choice autocorrelation function
    p_rt_explore = p_rt_explore./(sum(p_rt_explore));  %% re-normalize choice probability so that it adds up to 1
end


%compared to other models that use a curve over which to choose,
%kalman_uv_logistic computes explore and exploit choices and chooses according to a logistic.
u_final = sum(u_func)/length(u_func);

sigmoid = 1/(1+exp(-discrim.*(u_final - inG.u_threshold))); %Rasch model with tradeoff as difficulty (location) parameter

p_choice_final = (((1 - sigmoid).*p_rt_explore) +  (sigmoid.*p_rt_exploit));


if inG.multinomial
    gx = p_choice_final';
else
    best_rts = find(p_choice_final==max(p_choice_final));
    gx = mean(best_rts);
end